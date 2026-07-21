defmodule Imp.MCP do
  @moduledoc """
  MCP tool catalog importer.

  `Imp.MCP.import_tools/1` converts either an in-process catalog or a
  transport-backed catalog into ordinary `Imp.Tool` values. Imported tools
  validate required fields and basic JSON-schema-style property constraints.

  Tool schemas follow the MCP specification dialect: the input contract is the
  camelCase `"inputSchema"` key (MCP spec, Tool definition) and `"description"`
  is optional. For in-process Elixir catalogs the snake_case `:input_schema`
  key is accepted as a documented back-compat fallback; wire transports always
  see spec-compliant servers use `inputSchema`.
  """

  @client_info %{"name" => "imp", "version" => "0.1.0"}

  @doc false
  def initialize_params(protocol_version) do
    # MCP spec, Lifecycle: initialize MUST carry protocolVersion, capabilities,
    # and clientInfo. An empty params object is non-compliant.
    %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{},
      "clientInfo" => @client_info
    }
  end

  defmodule Catalog do
    @moduledoc "In-process MCP-like catalog used for tests and adapters."
    defstruct tools: []

    def new(tools) when is_list(tools), do: %__MODULE__{tools: tools}

    def new(tools) do
      raise ArgumentError,
            "Imp.MCP.Catalog.new/1 expects a list of tool schemas; got: #{inspect(tools)}"
    end

    def list_tools(%__MODULE__{tools: tools}), do: tools
  end

  @doc false
  def json_rpc_result(%{"error" => error}), do: {:error, {:json_rpc_error, error}}
  def json_rpc_result(%{"result" => result}), do: {:ok, result}
  def json_rpc_result(%{error: error}), do: {:error, {:json_rpc_error, error}}
  def json_rpc_result(%{result: result}), do: {:ok, result}
  def json_rpc_result(other), do: {:ok, other}

  defmodule HTTPRecovery do
    @moduledoc false

    require Logger

    @transient_statuses [408, 429, 500, 502, 503, 504]

    def option_schema do
      [
        max_attempts: [type: :pos_integer],
        timeout: [type: :pos_integer],
        retry_delay: [type: :non_neg_integer],
        max_retry_after: [type: :non_neg_integer],
        idempotency_key: [type: {:custom, __MODULE__, :validate_idempotency_key, []}],
        transport_opts: [type: :keyword_list]
      ]
    end

    def defaults do
      [
        max_attempts: 3,
        timeout: 5_000,
        retry_delay: 100,
        max_retry_after: 1_000,
        idempotency_key: nil,
        transport_opts: []
      ]
    end

    def validate_idempotency_key(nil), do: {:ok, nil}

    def validate_idempotency_key(callback) when is_function(callback, 2),
      do: {:ok, callback}

    def validate_idempotency_key(_callback),
      do: {:error, "expected nil or an arity-2 function"}

    def request(client, event_prefix, method, params, headers) do
      id = System.unique_integer([:positive])

      body =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

      with {:ok, replay} <- replay_contract(client, method, params) do
        headers = add_idempotency_header(headers, replay)
        max_attempts = effective_max_attempts(client, replay)

        Imp.Telemetry.span(event_prefix, span_metadata(method, id, max_attempts, replay), fn ->
          attempt(client, event_prefix, method, id, body, headers, replay, 1, max_attempts)
        end)
      end
    end

    def notification(client, event_prefix, method, params, headers) do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
      metadata = span_metadata(method, nil, 1, :never)

      Imp.Telemetry.span(event_prefix, metadata, fn ->
        run_attempt(client, event_prefix, method, nil, body, headers, :never, 1, 1)
      end)
    end

    defp attempt(
           client,
           event_prefix,
           method,
           id,
           body,
           headers,
           replay,
           attempt,
           max_attempts
         ) do
      result =
        run_attempt(
          client,
          event_prefix,
          method,
          id,
          body,
          headers,
          replay,
          attempt,
          max_attempts
        )

      if retry?(result, replay, attempt, max_attempts) do
        Process.sleep(retry_delay(result, attempt, client))

        attempt(
          client,
          event_prefix,
          method,
          id,
          body,
          headers,
          replay,
          attempt + 1,
          max_attempts
        )
      else
        result
      end
    end

    defp run_attempt(
           client,
           event_prefix,
           method,
           id,
           body,
           headers,
           replay,
           attempt,
           max_attempts
         ) do
      started = System.monotonic_time()

      task =
        Task.async(fn ->
          opts =
            client.transport_opts
            |> Keyword.put(:timeout, client.timeout)
            |> Keyword.put(:receive_timeout, client.timeout)
            |> Keyword.put(:retry, false)

          Imp.HTTP.post(client.transport, client.url, headers, body, opts)
        end)

      result =
        case Task.yield(task, client.timeout) do
          {:ok, result} ->
            result

          {:exit, reason} ->
            {:error, {:transport_exit, reason}}

          nil ->
            Task.shutdown(task, :brutal_kill)
            {:error, :timeout}
        end

      Imp.Telemetry.execute(
        event_prefix ++ [:attempt],
        %{duration: System.monotonic_time() - started},
        %{
          transport: :http,
          method: method,
          request_id: id,
          attempt: attempt,
          max_attempts: max_attempts,
          replay: replay_kind(replay),
          outcome: outcome(result)
        }
      )

      result
    end

    defp replay_contract(_client, "tools/list", _params),
      do: {:ok, :idempotent}

    defp replay_contract(%{idempotency_key: nil}, _method, _params), do: {:ok, :never}

    defp replay_contract(%{idempotency_key: callback}, method, params) do
      case callback.(method, params) do
        key when is_binary(key) and byte_size(key) > 0 -> {:ok, {:idempotency_key, key}}
        nil -> {:ok, :never}
        other -> {:error, {:invalid_idempotency_key, other}}
      end
    end

    defp add_idempotency_header(headers, {:idempotency_key, key}) do
      headers =
        Enum.reject(headers, fn {name, _value} ->
          name |> to_string() |> String.downcase() == "idempotency-key"
        end)

      [{"idempotency-key", key} | headers]
    end

    defp add_idempotency_header(headers, _replay), do: headers

    defp effective_max_attempts(_client, :never), do: 1
    defp effective_max_attempts(client, _replay), do: client.max_attempts

    defp retry?(_result, :never, _attempt, _max_attempts), do: false
    defp retry?(_result, _replay, attempt, max_attempts) when attempt >= max_attempts, do: false

    defp retry?({:ok, %{status: status}}, _replay, _attempt, _max),
      do: status in @transient_statuses

    defp retry?({:error, reason}, _replay, _attempt, _max), do: transient_transport?(reason)
    defp retry?(_result, _replay, _attempt, _max), do: false

    defp transient_transport?(reason)
         when reason in [
                :timeout,
                :econnrefused,
                :closed,
                :enetunreach,
                :ehostunreach,
                :pool_not_available,
                :unprocessed
              ],
         do: true

    defp transient_transport?({:http_transport_failed, _transport, reason}),
      do: transient_transport?(reason)

    defp transient_transport?({:failed_connect, details}) when is_list(details) do
      Enum.any?(details, &transient_detail?/1)
    end

    defp transient_transport?(%Req.TransportError{reason: reason}),
      do: transient_transport?(reason)

    defp transient_transport?(_reason), do: false

    defp transient_detail?(detail) when is_tuple(detail),
      do: detail |> Tuple.to_list() |> Enum.any?(&transient_detail?/1)

    defp transient_detail?(detail) when is_list(detail),
      do: Enum.any?(detail, &transient_detail?/1)

    defp transient_detail?(detail), do: transient_transport?(detail)

    defp retry_delay({:ok, %{status: status, headers: headers}}, attempt, client)
         when status in [429, 503] do
      case req_retry_after(headers) do
        delay when is_integer(delay) -> min(delay, client.max_retry_after)
        nil -> backoff(client.retry_delay, client.max_retry_after, attempt - 1)
      end
    end

    defp retry_delay(_result, attempt, client),
      do: backoff(client.retry_delay, client.max_retry_after, attempt - 1)

    defp req_retry_after(headers) do
      headers =
        Enum.map(headers, fn {name, value} ->
          {name |> to_string() |> String.downcase(), to_string(value)}
        end)

      [headers: headers]
      |> Req.Response.new()
      |> Req.Response.get_retry_after()
    rescue
      # Only parse failures are rescued (Req raises ArgumentError on a
      # Retry-After value that is neither delta-seconds nor an HTTP date).
      # Anything else propagates. The fallback to exponential backoff is
      # kept, but never silently.
      error in ArgumentError ->
        Logger.warning(
          "Imp.MCP: unparsable Retry-After header " <>
            "(#{Exception.message(error)}); falling back to exponential backoff"
        )

        nil
    end

    defp backoff(base, cap, exponent), do: min(base * Integer.pow(2, exponent), cap)

    defp span_metadata(method, id, max_attempts, replay) do
      %{
        transport: :http,
        method: method,
        request_id: id,
        max_attempts: max_attempts,
        replay: replay_kind(replay)
      }
    end

    defp replay_kind({:idempotency_key, _key}), do: :idempotency_key
    defp replay_kind(replay), do: replay

    defp outcome({:ok, %{status: status}}), do: {:http, status}
    defp outcome({:error, reason}) when reason in [:timeout, :econnrefused, :closed], do: reason
    defp outcome({:error, _reason}), do: :transport_error
    defp outcome(_other), do: :invalid_transport_response
  end

  defmodule HTTPClient do
    @moduledoc "JSON-RPC 2.0 transport-backed MCP-style catalog client."

    defstruct [
      :url,
      transport: Imp.HTTP.Hackneyless,
      headers: [],
      protocol_version: "2025-03-26",
      max_attempts: 3,
      timeout: 5_000,
      retry_delay: 100,
      max_retry_after: 1_000,
      idempotency_key: nil,
      transport_opts: []
    ]

    @option_schema Keyword.merge(
                     [
                       transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
                       headers: [type: {:list, {:tuple, [:any, :any]}}],
                       protocol_version: [type: :string]
                     ],
                     Imp.MCP.HTTPRecovery.option_schema()
                   )

    def new(url, opts \\ []) do
      validate_url!(url)
      opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

      struct!(
        __MODULE__,
        Keyword.merge(
          Imp.MCP.HTTPRecovery.defaults(),
          opts
        )
        |> Keyword.put(:url, url)
      )
    end

    def list_tools(%__MODULE__{} = client) do
      with {:ok, :initialized} <- initialize(client),
           {:ok, %{status: status, body: body}} when status in 200..299 <-
             post_json(client, "tools/list", %{}),
           {:ok, decoded} <- Jason.decode(body),
           {:ok, tools} <- decode_tools(decoded) do
        Enum.map(tools, &attach_remote_run(client, &1))
      else
        {:ok, %{status: status, body: body}} ->
          raise ArgumentError, "MCP tools/list HTTP #{status}: #{body}"

        {:error, reason} ->
          raise ArgumentError, "MCP tools/list failed: #{inspect(reason)}"
      end
    end

    defp decode_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{tools: tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{result: %{tools: tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(other), do: {:error, {:missing_tools, other}}

    defp initialize(client) do
      with {:ok, %{status: status}} when status in 200..299 <-
             post_json(client, "initialize", Imp.MCP.initialize_params(client.protocol_version)),
           {:ok, %{status: status}} when status in 200..299 <-
             post_notification(client, "notifications/initialized", %{}) do
        {:ok, :initialized}
      end
    end

    defp attach_remote_run(client, tool) do
      name = Map.get(tool, "name", Map.get(tool, :name))

      Map.put(tool, "run", fn arguments ->
        with {:ok, %{status: status, body: response}} when status in 200..299 <-
               post_json(client, "tools/call", %{"name" => name, "arguments" => arguments}),
             {:ok, decoded} <- Jason.decode(response),
             {:ok, result} <- Imp.MCP.json_rpc_result(decoded) do
          result
        else
          {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
          {:error, reason} -> {:error, reason}
        end
      end)
    end

    defp post_json(client, method, params) do
      Imp.MCP.HTTPRecovery.request(client, [:imp, :mcp, :http], method, params, headers(client))
    end

    defp post_notification(client, method, params) do
      Imp.MCP.HTTPRecovery.notification(
        client,
        [:imp, :mcp, :http],
        method,
        params,
        headers(client)
      )
    end

    defp headers(client),
      do: [
        {"content-type", "application/json"},
        {"mcp-protocol-version", client.protocol_version}
        | client.headers
      ]

    defp validate_url!(url) when is_binary(url), do: :ok

    defp validate_url!(url) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/2 expects url to be a binary; got: #{inspect(url)}"
    end
  end

  defmodule StdioClient do
    @moduledoc "Stdio JSON-RPC MCP client that opens a process per discovery or tool call."

    defstruct [
      :command,
      args: [],
      protocol_version: "2025-03-26",
      timeout: 5_000
    ]

    @option_schema [
      args: [type: {:list, :string}],
      protocol_version: [type: :string],
      timeout: [type: :pos_integer]
    ]

    def new(command, opts \\ []) do
      validate_command!(command)
      opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

      %__MODULE__{
        command: command,
        args: Keyword.get(opts, :args, []),
        protocol_version: Keyword.get(opts, :protocol_version, "2025-03-26"),
        timeout: Keyword.get(opts, :timeout, 5_000)
      }
    end

    def encode(method, params \\ %{}, id \\ next_id()) do
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <>
        "\n"
    end

    def list_tools(%__MODULE__{} = client) do
      {port, os_pid} = open_port(client)

      try do
        with {:ok, _} <-
               request(
                 port,
                 "initialize",
                 Imp.MCP.initialize_params(client.protocol_version),
                 client.timeout
               ),
             :ok <- notify(port, "notifications/initialized", %{}),
             {:ok, decoded} <- request(port, "tools/list", %{}, client.timeout),
             {:ok, tools} <- decode_tools(decoded) do
          Enum.map(tools, &attach_stdio_run(client, &1))
        else
          {:error, reason} -> raise ArgumentError, "MCP stdio failed: #{inspect(reason)}"
        end
      after
        safe_close(port, os_pid)
      end
    end

    defp attach_stdio_run(client, tool) do
      name = Map.get(tool, "name", Map.get(tool, :name))

      Map.put(tool, "run", fn arguments ->
        {port, os_pid} = open_port(client)

        try do
          with {:ok, _} <-
                 request(
                   port,
                   "initialize",
                   Imp.MCP.initialize_params(client.protocol_version),
                   client.timeout
                 ),
               :ok <- notify(port, "notifications/initialized", %{}),
               {:ok, decoded} <-
                 request(
                   port,
                   "tools/call",
                   %{"name" => name, "arguments" => arguments},
                   client.timeout
                 ),
               {:ok, result} <- Imp.MCP.json_rpc_result(decoded) do
            result
          end
        after
          safe_close(port, os_pid)
        end
      end)
    end

    # Closing the port alone only closes stdin; a server that ignores stdin EOF
    # (or is stuck past the request timeout) survives as an orphan OS process.
    # Reuse the shared TERM -> grace -> KILL process-group teardown instead.
    defp safe_close(port, os_pid) do
      Imp.ExternalCommand.Lifecycle.terminate_port_group(port, os_pid)
    end

    defp open_port(%__MODULE__{} = client) do
      port =
        Port.open({:spawn_executable, client.command}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: client.args
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> os_pid
          nil -> nil
        end

      {port, os_pid}
    end

    defp request(port, method, params, timeout) do
      id = next_id()
      deadline = System.monotonic_time(:millisecond) + timeout

      Imp.Telemetry.span([:imp, :mcp, :stdio], %{method: method}, fn ->
        Port.command(port, encode(method, params, id))
        read_response(port, id, "", deadline)
      end)
    end

    defp notify(port, method, params) do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"

      Imp.Telemetry.span([:imp, :mcp, :stdio], %{method: method}, fn ->
        Port.command(port, body)
        :ok
      end)
    end

    defp read_response(port, id, buffer, deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          case decode_line(buffer, id) do
            {:ok, decoded} -> {:ok, decoded}
            :more -> read_response(port, id, buffer, deadline)
            {:error, reason} -> {:error, reason}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:stdio_exit, status}}
      after
        remaining -> {:error, :timeout}
      end
    end

    defp decode_line(buffer, id) do
      buffer
      |> String.split("\n", trim: true)
      |> Enum.find_value(:more, fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, {:json_rpc_error, error}}
          {:ok, %{"id" => ^id} = decoded} -> {:ok, decoded}
          _other -> false
        end
      end)
    end

    defp decode_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(other), do: {:error, {:missing_tools, other}}

    defp next_id, do: System.unique_integer([:positive])

    defp validate_command!(command) when is_binary(command), do: :ok

    defp validate_command!(command) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/2 expects command to be a binary executable path; got: #{inspect(command)}"
    end
  end

  defmodule StreamableHTTPClient do
    @moduledoc "MCP Streamable HTTP client with session-aware headers and SSE decoding."

    defstruct [
      :url,
      :session_id,
      transport: Imp.HTTP.Hackneyless,
      headers: [],
      protocol_version: "2025-03-26",
      max_attempts: 3,
      timeout: 5_000,
      retry_delay: 100,
      max_retry_after: 1_000,
      idempotency_key: nil,
      transport_opts: []
    ]

    @option_schema Keyword.merge(
                     [
                       transport: [type: {:custom, Imp.HTTP, :validate_transport, []}],
                       headers: [type: {:list, {:tuple, [:any, :any]}}],
                       session_id: [type: {:or, [:string, nil]}],
                       protocol_version: [type: :string]
                     ],
                     Imp.MCP.HTTPRecovery.option_schema()
                   )

    def new(url, opts \\ []) do
      validate_url!(url)
      opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

      struct!(
        __MODULE__,
        Keyword.merge(
          Imp.MCP.HTTPRecovery.defaults(),
          opts
        )
        |> Keyword.put(:url, url)
      )
    end

    def list_tools(%__MODULE__{} = client) do
      with {:ok, client} <- initialize(client),
           {:ok, decoded} <- rpc(client, "tools/list", %{}),
           {:ok, tools} <- decode_tools(decoded) do
        Enum.map(tools, &attach_remote_run(client, &1))
      else
        {:error, reason} -> raise ArgumentError, "MCP streamable HTTP failed: #{inspect(reason)}"
      end
    end

    # MCP spec, Lifecycle + Streamable HTTP transport:
    # 1. initialize carries full params (protocolVersion, capabilities, clientInfo);
    # 2. if the server assigns an Mcp-Session-Id header on the initialize
    #    response, the client MUST include it on all subsequent requests;
    # 3. after a successful initialize the client MUST send the
    #    notifications/initialized notification (the server responds 202
    #    Accepted with no body, so the response is not JSON-decoded).
    defp initialize(client) do
      with {:ok, %{status: status, headers: response_headers, body: body}}
           when status in 200..299 <-
             Imp.MCP.HTTPRecovery.request(
               client,
               [:imp, :mcp, :streamable_http],
               "initialize",
               Imp.MCP.initialize_params(client.protocol_version),
               headers(client)
             ),
           {:ok, decoded} <- decode_body(body),
           {:ok, _result} <- Imp.MCP.json_rpc_result(decoded) do
        client = capture_session(client, response_headers)
        notify_initialized(client)
      else
        {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp notify_initialized(client) do
      case Imp.MCP.HTTPRecovery.notification(
             client,
             [:imp, :mcp, :streamable_http],
             "notifications/initialized",
             %{},
             headers(client)
           ) do
        {:ok, %{status: status}} when status in 200..299 -> {:ok, client}
        {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end

    # A server-assigned session id supersedes any preconfigured one; without a
    # server assignment the configured session id (session resumption) stands.
    defp capture_session(client, response_headers) do
      case session_id(response_headers) do
        nil -> client
        session_id -> %{client | session_id: session_id}
      end
    end

    defp session_id(headers) do
      Enum.find_value(headers, fn {name, value} ->
        if name |> to_string() |> String.downcase() == "mcp-session-id",
          do: to_string(value)
      end)
    end

    def headers(%__MODULE__{} = client) do
      base = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", client.protocol_version}
        | client.headers
      ]

      if client.session_id, do: [{"mcp-session-id", client.session_id} | base], else: base
    end

    defp attach_remote_run(client, tool) do
      name = Map.get(tool, "name", Map.get(tool, :name))

      Map.put(tool, "run", fn arguments ->
        with {:ok, decoded} <-
               rpc(client, "tools/call", %{"name" => name, "arguments" => arguments}),
             {:ok, result} <- Imp.MCP.json_rpc_result(decoded) do
          result
        end
      end)
    end

    defp rpc(client, method, params) do
      with {:ok, %{status: status, body: response}} when status in 200..299 <-
             Imp.MCP.HTTPRecovery.request(
               client,
               [:imp, :mcp, :streamable_http],
               method,
               params,
               headers(client)
             ),
           {:ok, decoded} <- decode_body(response) do
        {:ok, decoded}
      else
        {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp decode_body(body) do
      cond do
        String.contains?(body, "\ndata:") or String.starts_with?(body, "data:") ->
          body
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "data:"))
          |> Enum.map(&String.trim_leading(&1, "data:"))
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or &1 == "[DONE]"))
          |> List.last()
          |> Jason.decode()

        true ->
          Jason.decode(body)
      end
    end

    defp decode_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(other), do: {:error, {:missing_tools, other}}

    defp validate_url!(url) when is_binary(url), do: :ok

    defp validate_url!(url) do
      raise ArgumentError,
            "#{inspect(__MODULE__)}.new/2 expects url to be a binary; got: #{inspect(url)}"
    end
  end

  @doc "Imports a catalog or list of tool schemas into `Imp.Tool` structs."
  def import_tools(catalog) do
    catalog
    |> list_tools()
    |> validate_tool_list!()
    |> validate_tool_schemas!()
    |> validate_unique_names!()
    |> Enum.map(&tool_from_schema/1)
  end

  defp list_tools(%{__struct__: module} = catalog) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :list_tools, 1) ->
        call_catalog(fn -> module.list_tools(catalog) end, module)

      Map.has_key?(catalog, :tools) ->
        Map.fetch!(catalog, :tools)

      true ->
        raise ArgumentError,
              "MCP catalog #{inspect(module)} must export list_tools/1 or contain a :tools field"
    end
  end

  defp list_tools(tools) when is_list(tools), do: tools

  defp call_catalog(fun, module) do
    fun.()
  rescue
    error ->
      raise ArgumentError,
            "MCP catalog #{inspect(module)} list_tools/1 failed: #{Exception.message(error)}"
  catch
    kind, reason ->
      raise ArgumentError,
            "MCP catalog #{inspect(module)} list_tools/1 failed: #{inspect({kind, reason})}"
  end

  defp validate_tool_list!(tools) when is_list(tools), do: tools

  defp validate_tool_list!(other) do
    raise ArgumentError, "MCP catalog list_tools/1 must return a list, got: #{inspect(other)}"
  end

  defp validate_tool_schemas!(tools) do
    Enum.map(tools, fn
      schema when is_map(schema) ->
        schema

      other ->
        raise ArgumentError, "MCP tool schema must be a map, got: #{inspect(other)}"
    end)
  end

  defp tool_from_schema(schema) when is_map(schema) do
    name = validate_tool_name!(fetch_required!(schema, :name))
    description = validate_description!(fetch_description(schema), name)
    input_schema = validate_input_schema!(fetch_input_schema!(schema, name), name)
    run = validate_run!(fetch_required!(schema, :run), name)

    Imp.Tool.new(
      name,
      description,
      fn input ->
        with :ok <- validate_tool_input(input, input_schema) do
          run.(input)
        end
      end,
      schema: input_schema
    )
  end

  defp validate_unique_names!(tools) do
    names = Enum.map(tools, &fetch_required!(&1, :name))
    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] ->
        tools

      duplicate_names ->
        raise ArgumentError, "duplicate MCP tool names: #{inspect(duplicate_names)}"
    end
  end

  defp validate_tool_name!(name) when is_atom(name) or is_binary(name), do: name

  defp validate_tool_name!(name) do
    raise ArgumentError, "MCP tool name must be an atom or string, got: #{inspect(name)}"
  end

  # MCP spec, Tool definition: description is optional. The MCP reference SDK
  # types it Optional[str], so both an absent key and an explicit null mean
  # "no description". Imp normalizes both to "" because downstream consumers
  # (adapters, Imp.ProgramParameters) require string descriptions.
  defp fetch_description(schema) do
    case fetch_optional(schema, :description, :__missing__) do
      :__missing__ -> ""
      nil -> ""
      description -> description
    end
  end

  # MCP spec, Tool definition: the input contract key is camelCase
  # "inputSchema". The snake_case :input_schema spelling is a documented
  # back-compat fallback for in-process Elixir catalogs only.
  defp fetch_input_schema!(schema, name) do
    case fetch_optional(schema, :inputSchema, :__missing__) do
      :__missing__ ->
        case fetch_optional(schema, :input_schema, :__missing__) do
          :__missing__ ->
            raise ArgumentError,
                  "MCP tool #{inspect(name)} schema missing inputSchema " <>
                    "(MCP spec camelCase; snake_case input_schema is accepted " <>
                    "only as an in-process catalog fallback)"

          input_schema ->
            input_schema
        end

      input_schema ->
        input_schema
    end
  end

  defp validate_description!(description, _name) when is_binary(description), do: description

  defp validate_description!(description, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} description must be a string, got: #{inspect(description)}"
  end

  defp validate_input_schema!(schema, _name) when is_map(schema), do: schema

  defp validate_input_schema!(schema, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} inputSchema must be a map, got: #{inspect(schema)}"
  end

  defp validate_run!(run, _name) when is_function(run, 1), do: run

  defp validate_run!(run, name) do
    raise ArgumentError,
          "MCP tool #{inspect(name)} run must be a one-argument function, got: #{inspect(run)}"
  end

  defp validate_tool_input(input, schema) do
    with :ok <- validate_required(input, schema),
         :ok <- validate_properties(input, schema) do
      :ok
    end
  end

  defp validate_required(input, schema) do
    missing =
      schema
      |> fetch_optional(:required, [])
      |> Enum.reject(&present?(input, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required, keys}}
    end
  end

  defp validate_properties(input, schema) do
    errors =
      schema
      |> fetch_optional(:properties, %{})
      |> Enum.flat_map(fn {name, property_schema} ->
        case fetch_input(input, name) do
          {:ok, value} -> validate_value(name, value, property_schema)
          :error -> []
        end
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:schema_validation, errors}}
    end
  end

  defp validate_value(name, value, schema) do
    []
    |> validate_type(name, value, fetch_optional(schema, :type))
    |> validate_enum(name, value, fetch_optional(schema, :enum))
    |> validate_minimum(name, value, fetch_optional(schema, :minimum))
    |> validate_maximum(name, value, fetch_optional(schema, :maximum))
  end

  defp validate_type(errors, _name, _value, nil), do: errors

  defp validate_type(errors, name, value, type) do
    valid? =
      case type do
        "string" -> is_binary(value)
        :string -> is_binary(value)
        "integer" -> is_integer(value)
        :integer -> is_integer(value)
        "number" -> is_number(value)
        :number -> is_number(value)
        "boolean" -> is_boolean(value)
        :boolean -> is_boolean(value)
        "array" -> is_list(value)
        :array -> is_list(value)
        "object" -> is_map(value)
        :object -> is_map(value)
        _ -> true
      end

    if valid?,
      do: errors,
      else: errors ++ [%{field: name, rule: :type, message: "expected #{type}"}]
  end

  defp validate_enum(errors, _name, _value, nil), do: errors

  defp validate_enum(errors, name, value, allowed) do
    if value in allowed,
      do: errors,
      else: errors ++ [%{field: name, rule: :enum, message: "must be one of #{inspect(allowed)}"}]
  end

  defp validate_minimum(errors, _name, _value, nil), do: errors

  defp validate_minimum(errors, name, value, min) when is_number(value) and value < min,
    do: errors ++ [%{field: name, rule: :minimum, message: "must be >= #{min}"}]

  defp validate_minimum(errors, _name, _value, _min), do: errors

  defp validate_maximum(errors, _name, _value, nil), do: errors

  defp validate_maximum(errors, name, value, max) when is_number(value) and value > max,
    do: errors ++ [%{field: name, rule: :maximum, message: "must be <= #{max}"}]

  defp validate_maximum(errors, _name, _value, _max), do: errors

  defp fetch_required!(map, key) do
    case fetch_optional(map, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "MCP tool schema missing #{key}"
      value -> value
    end
  end

  defp fetch_optional(map, key, default \\ nil)

  defp fetch_optional(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_optional(map, key, default), do: Map.get(map, key, default)

  defp present?(input, key),
    do: match?({:ok, value} when not is_nil(value), fetch_input(input, key))

  defp fetch_input(input, key) when is_atom(key),
    do: Map.fetch(input, key) |> or_fetch(input, Atom.to_string(key))

  defp fetch_input(input, key) when is_binary(key) do
    case Map.fetch(input, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case existing_atom(key) do
          {:ok, atom} -> Map.fetch(input, atom)
          :error -> :error
        end
    end
  end

  defp or_fetch({:ok, value}, _input, _key), do: {:ok, value}
  defp or_fetch(:error, input, key), do: Map.fetch(input, key)

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end
