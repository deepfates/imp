defmodule DSEx.MCP do
  @moduledoc """
  MCP-style tool catalog importer.

  `DSEx.MCP.import_tools/1` converts either an in-process catalog or a
  transport-backed HTTP catalog into ordinary `DSEx.Tool` values. Imported tools
  validate required fields and basic JSON-schema-style property constraints.
  """

  defmodule Catalog do
    @moduledoc "In-process MCP-like catalog used for tests and adapters."
    defstruct tools: []

    def new(tools), do: %__MODULE__{tools: tools}
    def list_tools(%__MODULE__{tools: tools}), do: tools
  end

  defmodule HTTPClient do
    @moduledoc "JSON-RPC 2.0 transport-backed MCP-style catalog client."

    defstruct [
      :url,
      transport: DSEx.HTTP.Hackneyless,
      headers: [],
      protocol_version: "2025-03-26"
    ]

    @option_schema [
      transport: [type: :any],
      headers: [type: {:list, {:tuple, [:any, :any]}}],
      protocol_version: [type: :string]
    ]

    def new(url, opts \\ []) do
      opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

      %__MODULE__{
        url: url,
        transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
        headers: Keyword.get(opts, :headers, []),
        protocol_version: Keyword.get(opts, :protocol_version, "2025-03-26")
      }
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
             post_json(client, "initialize", %{
               "protocolVersion" => client.protocol_version,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "dsex", "version" => "0.1.0"}
             }),
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
             {:ok, result} <- json_rpc_result(decoded) do
          result
        else
          {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
          {:error, reason} -> {:error, reason}
        end
      end)
    end

    defp json_rpc_result(%{"error" => error}), do: {:error, {:json_rpc_error, error}}
    defp json_rpc_result(%{"result" => result}), do: {:ok, result}
    defp json_rpc_result(%{error: error}), do: {:error, {:json_rpc_error, error}}
    defp json_rpc_result(%{result: result}), do: {:ok, result}
    defp json_rpc_result(other), do: {:ok, other}

    defp post_json(client, method, params) do
      body = %{"jsonrpc" => "2.0", "id" => next_id(), "method" => method, "params" => params}

      DSEx.Telemetry.span([:dsex, :mcp, :http], %{url: client.url, method: method}, fn ->
        DSEx.HTTP.post(client.transport, client.url, headers(client), Jason.encode!(body), [])
      end)
    end

    defp post_notification(client, method, params) do
      body = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

      DSEx.Telemetry.span([:dsex, :mcp, :http], %{url: client.url, method: method}, fn ->
        DSEx.HTTP.post(client.transport, client.url, headers(client), Jason.encode!(body), [])
      end)
    end

    defp headers(client),
      do: [
        {"content-type", "application/json"},
        {"mcp-protocol-version", client.protocol_version}
        | client.headers
      ]

    defp next_id, do: System.unique_integer([:positive])
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
      opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

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
      port = open_port(client)

      try do
        with {:ok, _} <-
               request(
                 port,
                 "initialize",
                 %{
                   "protocolVersion" => client.protocol_version,
                   "capabilities" => %{},
                   "clientInfo" => %{"name" => "dsex", "version" => "0.1.0"}
                 },
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
        safe_close(port)
      end
    end

    defp attach_stdio_run(client, tool) do
      name = Map.get(tool, "name", Map.get(tool, :name))

      Map.put(tool, "run", fn arguments ->
        port = open_port(client)

        try do
          with {:ok, _} <- request(port, "initialize", %{}, client.timeout),
               :ok <- notify(port, "notifications/initialized", %{}),
               {:ok, decoded} <-
                 request(
                   port,
                   "tools/call",
                   %{"name" => name, "arguments" => arguments},
                   client.timeout
                 ) do
            Map.get(decoded, "result", decoded)
          end
        after
          safe_close(port)
        end
      end)
    end

    defp safe_close(port) do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    defp open_port(%__MODULE__{} = client) do
      Port.open({:spawn_executable, client.command}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: client.args
      ])
    end

    defp request(port, method, params, timeout) do
      id = next_id()

      DSEx.Telemetry.span([:dsex, :mcp, :stdio], %{method: method}, fn ->
        Port.command(port, encode(method, params, id))
        read_response(port, id, "", timeout)
      end)
    end

    defp notify(port, method, params) do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"

      DSEx.Telemetry.span([:dsex, :mcp, :stdio], %{method: method}, fn ->
        Port.command(port, body)
        :ok
      end)
    end

    defp read_response(port, id, buffer, timeout) do
      receive do
        {^port, {:data, data}} ->
          buffer = buffer <> data

          case decode_line(buffer, id) do
            {:ok, decoded} -> {:ok, decoded}
            :more -> read_response(port, id, buffer, timeout)
            {:error, reason} -> {:error, reason}
          end

        {^port, {:exit_status, status}} ->
          {:error, {:stdio_exit, status}}
      after
        timeout -> {:error, :timeout}
      end
    end

    defp decode_line(buffer, id) do
      buffer
      |> String.split("\n", trim: true)
      |> Enum.find_value(:more, fn line ->
        case Jason.decode(line) do
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, error}
          {:ok, %{"id" => ^id} = decoded} -> {:ok, decoded}
          _other -> false
        end
      end)
    end

    defp decode_tools(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
    defp decode_tools(other), do: {:error, {:missing_tools, other}}

    defp next_id, do: System.unique_integer([:positive])
  end

  defmodule StreamableHTTPClient do
    @moduledoc "MCP Streamable HTTP client with session-aware headers and SSE decoding."

    defstruct [
      :url,
      :session_id,
      transport: DSEx.HTTP.Hackneyless,
      headers: [],
      protocol_version: "2025-03-26"
    ]

    @option_schema [
      transport: [type: :any],
      headers: [type: {:list, {:tuple, [:any, :any]}}],
      session_id: [type: {:or, [:string, nil]}],
      protocol_version: [type: :string]
    ]

    def new(url, opts \\ []) do
      opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.new/2")

      %__MODULE__{
        url: url,
        transport: Keyword.get(opts, :transport, DSEx.HTTP.Hackneyless),
        headers: Keyword.get(opts, :headers, []),
        session_id: Keyword.get(opts, :session_id),
        protocol_version: Keyword.get(opts, :protocol_version, "2025-03-26")
      }
    end

    def list_tools(%__MODULE__{} = client) do
      with {:ok, _} <- rpc(client, "initialize", %{}),
           {:ok, decoded} <- rpc(client, "tools/list", %{}),
           {:ok, tools} <- decode_tools(decoded) do
        Enum.map(tools, &attach_remote_run(client, &1))
      else
        {:error, reason} -> raise ArgumentError, "MCP streamable HTTP failed: #{inspect(reason)}"
      end
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
             {:ok, result} <- json_rpc_result(decoded) do
          result
        end
      end)
    end

    defp json_rpc_result(%{"error" => error}), do: {:error, {:json_rpc_error, error}}
    defp json_rpc_result(%{"result" => result}), do: {:ok, result}
    defp json_rpc_result(%{error: error}), do: {:error, {:json_rpc_error, error}}
    defp json_rpc_result(%{result: result}), do: {:ok, result}
    defp json_rpc_result(other), do: {:ok, other}

    defp rpc(client, method, params) do
      body = %{"jsonrpc" => "2.0", "id" => next_id(), "method" => method, "params" => params}

      DSEx.Telemetry.span(
        [:dsex, :mcp, :streamable_http],
        %{url: client.url, method: method},
        fn ->
          with {:ok, %{status: status, body: response}} when status in 200..299 <-
                 DSEx.HTTP.post(
                   client.transport,
                   client.url,
                   headers(client),
                   Jason.encode!(body),
                   []
                 ),
               {:ok, decoded} <- decode_body(response) do
            {:ok, decoded}
          else
            {:ok, %{status: status, body: response}} -> {:error, {:http_error, status, response}}
            {:error, reason} -> {:error, reason}
          end
        end
      )
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

    defp next_id, do: System.unique_integer([:positive])
  end

  @doc "Imports a catalog or list of tool schemas into `DSEx.Tool` structs."
  def import_tools(catalog) do
    catalog
    |> list_tools()
    |> validate_unique_names!()
    |> Enum.map(&tool_from_schema/1)
  end

  defp list_tools(%{__struct__: module} = catalog) do
    cond do
      function_exported?(module, :list_tools, 1) -> module.list_tools(catalog)
      true -> Map.fetch!(catalog, :tools)
    end
  end

  defp list_tools(tools) when is_list(tools), do: tools

  defp tool_from_schema(schema) when is_map(schema) do
    name = fetch_required!(schema, :name)
    description = fetch_required!(schema, :description)
    input_schema = fetch_required!(schema, :input_schema)
    run = fetch_required!(schema, :run)

    DSEx.Tool.new(
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
