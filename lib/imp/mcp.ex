defmodule Imp.MCP do
  @moduledoc """
  MCP tool catalog importer.

  `Imp.MCP.import_tools/1` converts either an in-process catalog or a
  transport-backed catalog into ordinary `Imp.Tool` values. Imported tools
  validate required fields and basic JSON-schema-style property constraints.

  Tool schemas follow the MCP specification dialect: the input contract is the
  camelCase `"inputSchema"` key (MCP spec, Tool definition) and `"description"`
  is optional. In-process Elixir catalogs may spell it `:input_schema`; that
  fallback applies to them only, since a spec-compliant server sends
  `inputSchema`.

  Transport clients default to `result_mode: :text`, matching DSPy's MCP tool
  boundary: one text block becomes a string, multiple text blocks become a
  list, and non-text blocks are returned when no text is present. Set
  `result_mode: :structured` to return `structuredContent` exactly when the
  server includes it—even when its value is `nil`, `false`, `0`, or empty—and
  fall back to the text conversion only when that field is absent. MCP error
  results become `{:error, {:mcp_tool_error, original_envelope}}` before either
  conversion. The original structured failure and content remain available;
  uncertainty about an effect must not be collapsed into a retryable refusal.
  """

  @doc """
  Connects authorized MCP servers; returns tools with source metadata and cleanup.

  `servers` is a list of descriptor maps, local (`"command"`) or remote
  (`"url"`); see `Imp.MCP.Connections` for their shape and every option.

      server = %{"name" => "files", "command" => "my-mcp-server", "args" => ["--stdio"]}
      {:ok, import} = Imp.MCP.connect([server], trusted_servers: [server])
      agent = Imp.react_v2("question -> answer", import.tools, lm: lm)
  """
  def connect(servers, opts \\ []), do: Imp.MCP.Connections.import_tools(servers, opts)

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

  @doc """
  The words a model reads for a failed MCP tool call.

  An error result (`{:mcp_tool_error, envelope}`) is the text its tool wrote:
  MCP spec, CallToolResult, puts what went wrong in the content, for the model
  to read. Its text items are joined; its structured content stands in as plain
  data when there is no text. A JSON-RPC error is the server's message. A call
  that got no answer is one sentence saying so and why. Unless the request was
  never sent, that sentence says it may have been carried out: a timeout, a
  closed or failed connection, a broken stream, or a server that stopped
  waiting for its tool does not say whether the tool ran, and a write that did
  run must not read as one that did not.

  This is only what is read. The error term itself, which the loop records,
  keeps the whole envelope or reason.

      iex> Imp.MCP.failure_text({:mcp_tool_call_failed, "kite", :timeout})
      "no answer came back; it timed out, so it may have been carried out."
  """
  @may_have_run "so it may have been carried out."

  @spec failure_text(term()) :: String.t()
  def failure_text(reason)

  def failure_text({:mcp_tool_error, envelope}), do: error_result_text(envelope)

  def failure_text({:mcp_tool_call_failed, _server, reason}) do
    case json_rpc_message(reason) do
      {:ok, message} -> message
      :error -> "no answer came back; " <> no_answer_reason(reason)
    end
  end

  def failure_text({:mcp_connection_unavailable, _server, exit_reason}),
    do: "no answer came back; " <> exit_prose(exit_reason)

  def failure_text({:json_rpc_error, error}) do
    case json_rpc_message(error) do
      {:ok, message} -> message
      :error -> "the server refused the call."
    end
  end

  defp error_result_text(envelope) when is_map(envelope) do
    texts =
      envelope
      |> fetch_field(:content, [])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and text_content?(&1)))
      |> Enum.map(&fetch_field(&1, :text, nil))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    cond do
      texts != [] ->
        Enum.join(texts, "\n")

      structured = fetch_field(envelope, :structuredContent, nil) ->
        Imp.Adapter.Chat.format_value(structured)

      true ->
        "The tool reported an error without saying what it was."
    end
  end

  defp error_result_text(_envelope), do: "The tool reported an error without saying what it was."

  # `ExMCP.Client.call_tool(format: :map)` returns a server's JSON-RPC error as
  # its decoded map; the `:struct` format wraps it in an `ExMCP.Error` or
  # `ExMCP.Error.ProtocolError` whose `:code` is an integer. ExMCP's server
  # failure classes (`data.type`) add a clause where they say something the
  # message does not; the others are identifiers, not words, and are left out.
  #
  # A handler that crashed or outlived the server's wait had started, so those
  # two read as a call that may have been carried out rather than by ExMCP's
  # "Tool call failed".
  defp json_rpc_message(%{"data" => %{"type" => "handler_crash"}}),
    do: {:ok, "the tool crashed while running, " <> @may_have_run}

  defp json_rpc_message(%{"data" => %{"type" => "handler_timeout"}}),
    do: {:ok, "the server stopped waiting for the tool, " <> @may_have_run}

  defp json_rpc_message(%{"message" => message} = error)
       when is_binary(message) and message != "",
       do: {:ok, message <> json_rpc_type_prose(Map.get(error, "data"))}

  defp json_rpc_message(%{message: message, code: code})
       when is_binary(message) and message != "" and is_integer(code),
       do: {:ok, message}

  defp json_rpc_message(_reason), do: :error

  defp json_rpc_type_prose(%{"type" => "handler_start_failed"}),
    do: "; the server could not start the tool."

  defp json_rpc_type_prose(_data), do: ""

  # The ways ExMCP reports a tool call that got no answer. Only a client that
  # is not connected, or not running, is known not to have sent the request.
  # ExMCP's other transport failures ("Failed to send request: ...") include
  # sockets that failed after the request went out, so they read as unknown.
  defp no_answer_reason(:not_connected), do: "the connection is not open."
  defp no_answer_reason(:timeout), do: "it timed out, " <> @may_have_run
  defp no_answer_reason(:closed), do: "the connection closed, " <> @may_have_run
  defp no_answer_reason(:cancelled), do: "the request was cancelled, " <> @may_have_run

  defp no_answer_reason(%ExMCP.Error.TransportError{reason: :outcome_unknown}),
    do: "the connection broke after the request was sent, " <> @may_have_run

  defp no_answer_reason(%ExMCP.Error.TransportError{reason: :timeout}),
    do: no_answer_reason(:timeout)

  defp no_answer_reason(%ExMCP.Error{code: :connection_error}), do: no_answer_reason(:closed)
  defp no_answer_reason(_reason), do: "the connection failed, " <> @may_have_run

  # The exit of a call to the client process names its pid and arguments; none
  # of that is for the reader.
  defp exit_prose({reason, {GenServer, :call, _args}}), do: exit_prose(reason)
  defp exit_prose(:timeout), do: no_answer_reason(:timeout)
  defp exit_prose(:noproc), do: no_answer_reason(:not_connected)
  defp exit_prose(_reason), do: no_answer_reason(:closed)

  @doc false
  def json_rpc_result(%{"error" => error}), do: {:error, {:json_rpc_error, error}}
  def json_rpc_result(%{"result" => result}), do: {:ok, result}
  def json_rpc_result(%{error: error}), do: {:error, {:json_rpc_error, error}}
  def json_rpc_result(%{result: result}), do: {:ok, result}
  def json_rpc_result(other), do: {:ok, other}

  @doc false
  def tool_result(result, mode \\ :text)

  def tool_result(result, mode) when mode in [:text, :structured] and is_map(result) do
    if call_tool_result?(result) do
      text = text_content(result)

      if fetch_field(result, :isError, false) do
        {:error, {:mcp_tool_error, result}}
      else
        convert_tool_result(result, mode, text)
      end
    else
      # An in-process adapter may return a bare application value instead of
      # an MCP CallToolResult envelope. Pass it through unchanged; only
      # envelopes are normalized.
      result
    end
  end

  def tool_result(result, mode) when mode in [:text, :structured], do: result

  defp call_tool_result?(result) do
    has_field?(result, :content) or has_field?(result, :structuredContent) or
      has_field?(result, :isError)
  end

  defp convert_tool_result(result, :structured, text) do
    case fetch_present(result, :structuredContent) do
      {:ok, value} -> value
      :error -> text_fallback(result, text)
    end
  end

  defp convert_tool_result(result, :text, text), do: text_fallback(result, text)

  defp text_fallback(result, []) do
    result
    |> fetch_field(:content, [])
    |> Enum.reject(&text_content?/1)
  end

  defp text_fallback(_result, text), do: text

  defp text_content(result) do
    texts =
      result
      |> fetch_field(:content, [])
      |> Enum.filter(&text_content?/1)
      |> Enum.map(&fetch_field(&1, :text, ""))

    case texts do
      [text] -> text
      texts -> texts
    end
  end

  defp text_content?(content), do: fetch_field(content, :type, nil) in ["text", :text]

  defp has_field?(map, name), do: match?({:ok, _value}, fetch_present(map, name))

  defp fetch_field(map, name, default) do
    case fetch_present(map, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_present(map, name) do
    names = [name, Atom.to_string(name), snake_case(name), Atom.to_string(snake_case(name))]

    Enum.find_value(names, :error, fn key ->
      if Map.has_key?(map, key), do: {:ok, Map.fetch!(map, key)}
    end)
  end

  defp snake_case(:structuredContent), do: :structured_content
  defp snake_case(:isError), do: :is_error
  defp snake_case(name), do: name

  defmodule Client do
    @moduledoc "An ExMCP-backed catalog. Close it when finished; owner exit also closes it."
    defstruct [:import]

    def new(server, opts \\ []) do
      opts = Keyword.put_new(opts, :trusted_servers, [server])

      case Imp.MCP.connect([server], opts) do
        {:ok, imported} -> %__MODULE__{import: imported}
        {:error, reason} -> raise ArgumentError, "MCP connection failed: #{inspect(reason)}"
      end
    end

    def close(%__MODULE__{import: imported}), do: imported.cleanup.()

    def list_tools(%__MODULE__{import: imported}) do
      Enum.map(imported.tools, fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          input_schema: tool.schema,
          metadata: tool.metadata,
          run: tool.run
        }
      end)
    end
  end

  defmodule HTTPClient do
    @moduledoc "MCP HTTP catalog backed by ExMCP; use Client.close/1 when finished."
    def new(url, opts \\ []) do
      {headers, opts} = Keyword.pop(opts, :headers, [])

      server = %{
        "name" => "http",
        "type" => "http",
        "url" => url,
        "headers" =>
          Enum.map(headers, fn {k, v} -> %{"name" => to_string(k), "value" => to_string(v)} end)
      }

      Imp.MCP.Client.new(server, opts)
    end

    defdelegate list_tools(client), to: Imp.MCP.Client
    defdelegate close(client), to: Imp.MCP.Client
  end

  defmodule StreamableHTTPClient do
    @moduledoc "MCP Streamable HTTP catalog using the shared ExMCP transport."
    defdelegate new(url, opts \\ []), to: Imp.MCP.HTTPClient
    defdelegate list_tools(client), to: Imp.MCP.Client
    defdelegate close(client), to: Imp.MCP.Client
  end

  defmodule StdioClient do
    @moduledoc "One owned ExMCP stdio connection shared by discovery and tool calls."
    def new(command, opts \\ []) do
      {args, opts} = Keyword.pop(opts, :args, [])
      {env, opts} = Keyword.pop(opts, :env, [])

      server = %{
        "name" => "stdio",
        "type" => "stdio",
        "command" => command,
        "args" => args,
        "env" =>
          Enum.map(env, fn {k, v} -> %{"name" => to_string(k), "value" => to_string(v)} end)
      }

      Imp.MCP.Client.new(server, opts)
    end

    defdelegate list_tools(client), to: Imp.MCP.Client
    defdelegate close(client), to: Imp.MCP.Client
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

    Imp.Tool.new(name, description, run,
      schema: input_schema,
      metadata: Map.get(schema, "metadata", Map.get(schema, :metadata, %{}))
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

  defp fetch_required!(map, key) do
    case fetch_optional(map, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "MCP tool schema missing #{key}"
      value -> value
    end
  end

  defp fetch_optional(map, key, default)

  defp fetch_optional(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_optional(map, key, default), do: Map.get(map, key, default)
end
