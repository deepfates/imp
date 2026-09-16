defmodule Imp.MCP.Import do
  @moduledoc """
  An owned remote tool catalog; cleanup closes its connections.

  `unavailable` is empty unless the import ran with `on_failure: :drop`, in
  which case it holds one `%{server: name, reason: reason}` entry per server
  that was left out. The tools of every server that did connect are in `tools`.
  """
  defstruct tools: [], annotations: %{}, provenance: %{}, cleanup: nil, unavailable: []

  @type absence :: %{server: String.t(), reason: term()}

  @type t :: %__MODULE__{
          tools: [Imp.Tool.t()],
          annotations: map(),
          provenance: map(),
          cleanup: (-> :ok),
          unavailable: [absence()]
        }
end

defmodule Imp.MCP.Connections do
  @moduledoc """
  Opens explicitly authorized MCP servers through ExMCP and imports their tools.
  Connections belong to `:owner` (the caller by default), independently of any
  ACP session. Exact descriptors must be approved through `:authorize` or
  `:trusted_servers`; connection cleanup never depends on a model-visible name.

  ## Authenticating an HTTP server

  A descriptor carries static `"headers"` as before. It can instead name an
  auth kind, which is resolved to a header when the connection is built and
  never written back into the descriptor:

      %{"type" => "oauth", "credential" => "readwise"}

  resolves through the `Imp.MCP.OAuth.Store` passed as the `:credentials`
  option, refreshing the grant when it is near expiry. The credential must have
  been authorized for this descriptor's `"url"`; naming another server's
  credential is refused rather than resolved. See `Imp.MCP.OAuth`.

      %{"type" => "bearer_env", "variable" => "EXA_API_KEY"}

  reads the variable from the host's environment. When it is unset the server
  is connected with no `Authorization` header and one warning naming the
  server and the variable is logged — a server that works anonymously, with
  rate limits, still works before the person has found a key. Add
  `"required" => true` to refuse the connection instead, with a message naming
  the variable.

  Both forms may be combined with static `"headers"`; the resolved header is
  appended. Tokens never appear in the descriptor, so authorization callbacks,
  `:call_meta` and tool provenance never see one.

  ## A server that cannot be reached

  By default (`on_failure: :refuse`) one unreachable server fails the whole
  import: every client is disconnected and an error is returned. That is right
  for a caller that needs all of its tools or none.

  `on_failure: :drop` is for a caller whose servers are independent — a
  long-lived agent holding several third-party catalogs, where one of them
  answering 503 this morning should cost that catalog and nothing else. A
  server whose transport or `initialize` fails, or which cannot answer
  `tools/list`, is left out: its client is closed, the servers beside it keep
  their tools, and the returned `Imp.MCP.Import` names it in `unavailable`
  with the reason the refusal would have carried, summarized to one short line.

  Dropping covers failures of the connection, not of the declaration. A
  descriptor that `:authorize` refused, one whose `auth` cannot produce a
  header (a `bearer_env` variable declared `required` and unset, for example),
  and one that is malformed all still refuse the import under either setting:
  they are decisions the caller made before anything was dialed, and silently
  continuing without them would discard the caller's own answer.
  """

  require Logger

  alias Imp.MCP.Import

  @type server :: map()
  @type context :: %{cwd: String.t(), server: server()}

  @option_keys [
    :authorize,
    :trusted_servers,
    :cwd,
    :timeout,
    :result_mode,
    :reserved_tool_names,
    :owner,
    :call_meta,
    :tool_filter,
    :credentials,
    :on_failure
  ]

  @doc """
  Connects authorized servers and imports all discovered tools.

  Returns an `Imp.MCP.Import` carrying the tools, the annotations each
  server declared for them, and stable source provenance independent of model-facing names.

  With `on_failure: :drop` a server that cannot be connected is left out and
  named in the import's `unavailable` list instead of failing the import.
  """
  @spec import_tools([server()], keyword()) :: {:ok, Import.t()} | {:error, term()}
  def import_tools(servers, opts \\ [])

  def import_tools(servers, opts) when is_list(servers) and is_list(opts) do
    validate_options!(opts)
    owner = Keyword.get(opts, :owner, self())

    unless is_pid(owner) do
      raise ArgumentError, ":owner must be a pid"
    end

    with :ok <- ensure_runtime(servers),
         {:ok, bridge} <- Imp.MCP.Clients.start(owner: owner) do
      case connect_isolated(servers, opts) do
        {:ok, clients, unavailable} ->
          :ok = Imp.MCP.Clients.adopt(bridge, clients)

          case tools_from_clients(clients, opts) do
            {:ok, tools, annotations, unlisted} ->
              {:ok,
               %Import{
                 tools: tools,
                 annotations: annotations,
                 provenance:
                   Map.new(tools, fn tool -> {to_string(tool.name), tool.metadata.mcp} end),
                 cleanup: cleanup_bridge(bridge),
                 unavailable: unavailable ++ unlisted
               }}

            {:error, reason} ->
              _ = Imp.MCP.Clients.stop(bridge)
              {:error, reason}
          end

        {:error, reason, clients} ->
          disconnect_all(clients)
          _ = Imp.MCP.Clients.stop(bridge)
          {:error, reason}

        {:error, reason} ->
          _ = Imp.MCP.Clients.stop(bridge)
          {:error, reason}
      end
    end
  end

  def import_tools(servers, _opts), do: {:error, {:invalid_mcp_servers, shape(servers)}}

  defp ensure_runtime([]), do: :ok

  defp ensure_runtime(_) do
    case Application.ensure_all_started(:ex_mcp) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:application_start_failed, reason}}
    end
  end

  # ExMCP may exit the connector on a bad handshake. Isolate connect so the ACP
  # session (or other :owner) survives, then adopt clients onto the session-owned
  # bridge. Do not rely on "remember to unlink from a spawn_monitor helper."
  defp connect_isolated(servers, opts) do
    parent = self()
    ref = make_ref()
    timeout = timeout(opts) + 5_000

    {pid, mon} =
      spawn_monitor(fn ->
        # A client whose transport refuses the connection answers
        # `ExMCP.Client.start_link/1` with an error and then exits, which kills
        # a caller that is not trapping. Without this flag every failure
        # reaches the caller as this helper's death, so no reason survives to
        # be reported and no server after the failing one is ever dialed.
        Process.flag(:trap_exit, true)

        result =
          try do
            connect_all(servers, opts, [], [])
          catch
            kind, reason -> {:error, {:mcp_connection_failed, {kind, reason}}, []}
          end

        case result do
          {:ok, clients, unavailable} ->
            Enum.each(clients, fn {_server, client} ->
              if Process.alive?(client), do: Process.unlink(client)
            end)

            send(parent, {ref, {:ok, clients, unavailable}})

          {:error, reason, clients} ->
            Enum.each(clients, fn {_server, client} ->
              if Process.alive?(client), do: Process.unlink(client)
            end)

            send(parent, {ref, {:error, reason, clients}})
        end
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:error, {:mcp_import_exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(mon, [:flush])
        {:error, :mcp_import_timeout}
    end
  end

  defp connect_all([], _opts, clients, unavailable),
    do: {:ok, Enum.reverse(clients), Enum.reverse(unavailable)}

  defp connect_all([server | rest], opts, clients, unavailable) when is_map(server) do
    server = stringify_keys(server)

    # Authorization and header resolution are separated from the dial because
    # only the dial is droppable: the first two are answers the caller already
    # gave, and `client_options/3` raises on a descriptor nobody can address.
    with :ok <- authorize(server, opts),
         {:ok, headers} <- connection_headers(server, opts),
         options = client_options(server, opts, headers),
         {:ok, client} <- start_client(options) do
      connect_all(rest, opts, [{server, client} | clients], unavailable)
    else
      {:unreachable, reason} ->
        if drop?(opts) do
          connect_all(rest, opts, clients, [absence(server, reason) | unavailable])
        else
          {:error, reason, clients}
        end

      {:error, reason} ->
        {:error, reason, clients}
    end
  rescue
    exception -> {:error, {:mcp_connection_failed, Exception.message(exception)}, clients}
  catch
    kind, reason -> {:error, {:mcp_connection_failed, {kind, reason}}, clients}
  end

  defp connect_all([server | _rest], _opts, clients, _unavailable),
    do: {:error, {:invalid_mcp_server, shape(server)}, clients}

  # A failed dial leaves nothing behind: `start_link/1` answers with an error
  # only after the client process has exited, and an exit it raises here is
  # this helper's own, with no client to close.
  defp start_client(options) do
    case ExMCP.Client.start_link(options) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:unreachable, {:mcp_connection_failed, reason}}
    end
  catch
    kind, reason -> {:unreachable, {:mcp_connection_failed, {kind, reason}}}
  end

  defp tools_from_clients(clients, opts) do
    clients
    |> Enum.reduce_while({:ok, [], []}, fn {server, client}, {:ok, acc, unavailable} ->
      case server_tools(server, client, opts) do
        {:ok, sourced} ->
          {:cont, {:ok, acc ++ sourced, unavailable}}

        {:error, reason} ->
          if drop?(opts) do
            # This one answered the handshake and then could not say what it
            # offers, so it contributes nothing. Close it here: an open client
            # nothing imported from would otherwise live as long as the import.
            safe_disconnect(client)
            {:cont, {:ok, acc, [absence(server, reason) | unavailable]}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, sourced_schemas, unavailable} ->
        with {:ok, schemas} <- disambiguate_tool_names(sourced_schemas, opts) do
          {:ok, Imp.MCP.import_tools(schemas), declared_annotations(schemas),
           Enum.reverse(unavailable)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, {:mcp_tool_import_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:mcp_tool_import_failed, {kind, reason}}}
  end

  defp server_tools(server, client, opts) do
    case ExMCP.Client.list_tools(client, format: :map, timeout: timeout(opts)) do
      {:ok, response} ->
        with {:ok, schemas} <- tool_schemas(response),
             {:ok, schemas} <- attach_client_runs(schemas, client, server, opts) do
          {:ok, Enum.map(schemas, &{server, &1})}
        end

      {:error, reason} ->
        {:error, {:mcp_tools_list_failed, server_name(server), reason}}
    end
  catch
    kind, reason -> {:error, {:mcp_tools_list_failed, server_name(server), {kind, reason}}}
  end

  defp drop?(opts), do: Keyword.get(opts, :on_failure, :refuse) == :drop

  # What the import says about a server it left out. The reason is the term the
  # refusal would have carried, with its detail summarized: a transport error
  # arrives as a nested struct whose inspection runs to several lines, and this
  # is read in a log line and an operator's report.
  defp absence(server, reason), do: %{server: server_name(server), reason: shorten(reason)}

  defp shorten({tag, detail}) when is_atom(tag), do: {tag, summary(detail)}

  defp shorten({tag, name, detail}) when is_atom(tag) and is_binary(name),
    do: {tag, name, summary(detail)}

  defp shorten(reason), do: reason

  defp summary(detail) when is_atom(detail), do: detail

  defp summary(detail) do
    text =
      if is_exception(detail),
        do: Exception.message(detail),
        else: inspect(detail, limit: 3, printable_limit: 120)

    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > 120, do: String.slice(text, 0, 119) <> "…", else: text
  end

  defp attach_client_runs(schemas, client, server, opts) do
    schemas =
      schemas
      |> Enum.filter(fn schema ->
        case Keyword.get(opts, :tool_filter) do
          nil -> true
          filter -> filter.(server, stringify_keys(schema)) == true
        end
      end)
      |> Enum.map(fn schema ->
        schema = stringify_keys(schema)
        name = Map.get(schema, "name")

        schema =
          Map.put(schema, "metadata", %{
            mcp: %{
              server_name: server_name(server),
              tool_name: name,
              schema: Map.drop(schema, ["run", "metadata"]),
              annotations: Map.get(schema, "annotations", %{})
            }
          })

        Map.put(schema, "run", fn arguments ->
          try do
            # A lost response does not establish that a write did not happen.
            # ExMCP defaults modern stream retries to at-least-once; this tool
            # boundary has no server idempotency contract, so never opt into it.
            case ExMCP.Client.call_tool(client, name, arguments,
                   format: :map,
                   retry_policy: false,
                   http_stream_retry: :safe_only,
                   timeout: timeout(opts),
                   meta: call_meta(server, opts)
                 ) do
              {:ok, result} -> Imp.MCP.tool_result(result, result_mode(opts))
              {:error, reason} -> {:error, {:mcp_tool_call_failed, server_name(server), reason}}
            end
          catch
            :exit, reason -> {:error, {:mcp_connection_unavailable, server_name(server), reason}}
          end
        end)
      end)

    {:ok, schemas}
  end

  defp call_meta(server, opts) do
    case Keyword.get(opts, :call_meta) do
      nil -> %{}
      callback -> callback.(server)
    end
  end

  # MCP tool names are scoped to one server, while an Imp program consumes one
  # flat catalog. Preserve the ordinary unqualified name when it is unique. If
  # independent servers publish the same name, qualify every conflicting tool
  # with its ACP server name so neither capability is silently discarded.
  defp disambiguate_tool_names(sourced_schemas, opts) do
    frequencies =
      Enum.frequencies_by(sourced_schemas, fn {_server, schema} ->
        schema |> Map.get("name") |> to_string()
      end)

    reserved_names =
      opts
      |> Keyword.get(:reserved_tool_names, [])
      |> MapSet.new(&to_string/1)

    sourced =
      Enum.map(sourced_schemas, fn {server, schema} ->
        original_name = schema |> Map.get("name") |> to_string()
        server_name = server_name(server)

        schema =
          if Map.fetch!(frequencies, original_name) > 1 or
               MapSet.member?(reserved_names, original_name) do
            schema
            |> Map.put("name", qualified_tool_name(server_name, original_name))
            |> Map.update(
              "description",
              "MCP tool #{original_name} from #{server_name}",
              &qualified_tool_description(&1, server_name, original_name)
            )
          else
            schema
          end

        {server_name, original_name, schema}
      end)

    generated_frequencies =
      Enum.frequencies_by(sourced, fn {_server, _original, schema} -> schema["name"] end)

    schemas =
      Enum.map(sourced, fn {server_name, original_name, schema} ->
        name = schema["name"]

        if Map.fetch!(generated_frequencies, name) > 1 or MapSet.member?(reserved_names, name) do
          Map.put(schema, "name", collision_qualified_tool_name(server_name, original_name))
        else
          schema
        end
      end)

    ensure_unique_tool_names(schemas, reserved_names)
  end

  # The tool declares its own nature in `annotations`; MCP carries that in
  # `tools/list` alongside the schema. Key it by the name the program will see,
  # which is the qualified name whenever disambiguation renamed the tool.
  defp declared_annotations(schemas) do
    schemas
    |> Enum.flat_map(fn schema ->
      case Map.get(schema, "annotations") do
        annotations when is_map(annotations) ->
          [{to_string(Map.get(schema, "name")), stringify_keys(annotations)}]

        _other ->
          []
      end
    end)
    |> Map.new()
  end

  defp qualified_tool_description(description, server_name, original_name)
       when is_binary(description) do
    suffix = "MCP server: #{server_name}; original tool: #{original_name}."

    case String.trim(description) do
      "" -> suffix
      text -> text <> " " <> suffix
    end
  end

  defp qualified_tool_description(_description, server_name, original_name),
    do: "MCP server: #{server_name}; original tool: #{original_name}."

  defp qualified_tool_name(server_name, tool_name) do
    full =
      "mcp_#{tool_name_segment(server_name, "server")}_#{tool_name_segment(tool_name, "tool")}"

    bounded_tool_name(full)
  end

  defp collision_qualified_tool_name(server_name, tool_name) do
    full = qualified_tool_name(server_name, tool_name)
    digest_source = server_name <> <<0>> <> tool_name

    digest =
      :crypto.hash(:sha256, digest_source) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    bounded_tool_name(full, digest)
  end

  defp bounded_tool_name(full, digest \\ nil)

  defp bounded_tool_name(full, nil) do
    if byte_size(full) <= 64 do
      full
    else
      digest = :crypto.hash(:sha256, full) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      binary_part(full, 0, 55) <> "_" <> digest
    end
  end

  defp bounded_tool_name(full, digest) do
    prefix_bytes = min(byte_size(full), 55)
    binary_part(full, 0, prefix_bytes) <> "_" <> digest
  end

  defp ensure_unique_tool_names(schemas, reserved_names) do
    names = Enum.map(schemas, & &1["name"])

    case Enum.find(names, fn name ->
           Enum.count(names, &(&1 == name)) > 1 or MapSet.member?(reserved_names, name)
         end) do
      nil -> {:ok, schemas}
      name -> {:error, {:mcp_tool_name_collision, name}}
    end
  end

  defp tool_name_segment(value, fallback) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/u, "_")
    |> String.trim("_")
    |> case do
      "" -> fallback
      segment -> segment
    end
  end

  defp tool_schemas(%{"tools" => tools}) when is_list(tools), do: {:ok, tools}

  defp tool_schemas(other),
    do: {:error, {:invalid_mcp_tools_response, shape(other)}}

  defp authorize(server, opts) do
    context = %{cwd: Keyword.get(opts, :cwd), server: server}

    result =
      case Keyword.get(opts, :authorize) do
        callback when is_function(callback, 2) -> safe_authorize(callback, server, context)
        callback when is_function(callback, 1) -> safe_authorize(callback, server)
        nil -> Enum.any?(Keyword.get(opts, :trusted_servers, []), &exact_server?(&1, server))
      end

    if result in [true, :ok],
      do: :ok,
      else: {:error, {:mcp_server_not_authorized, server_name(server)}}
  end

  defp safe_authorize(callback, server, context), do: callback.(server, context)
  defp safe_authorize(callback, server), do: callback.(server)

  defp exact_server?(trusted, server) when is_map(trusted),
    do: stringify_keys(trusted) == server

  defp exact_server?(_trusted, _server), do: false

  # A descriptor may name an auth kind instead of carrying a token. The token is
  # materialized here, when the connection is built, and is never written back
  # into the descriptor: authorization callbacks, `:call_meta` and imported tool
  # provenance all read the descriptor, and none of them should see a secret.
  defp connection_headers(server, opts) do
    case {server_type(server), Map.get(server, "auth")} do
      {type, nil} when type in ["http", "sse"] ->
        {:ok, static_headers(server)}

      {type, auth} when type in ["http", "sse"] and is_map(auth) ->
        with {:ok, resolved} <- resolve_auth(stringify_keys(auth), server, opts) do
          {:ok, static_headers(server) ++ resolved}
        end

      {type, _auth} when type in ["http", "sse"] ->
        {:error,
         auth_unavailable(
           server,
           ~s(auth must be a map naming a type, for example %{"type" => "oauth", ) <>
             ~s("credential" => "readwise"})
         )}

      {_type, nil} ->
        {:ok, []}

      {_type, _auth} ->
        {:error, auth_unavailable(server, "auth applies to http and sse servers only")}
    end
  end

  defp static_headers(server),
    do: name_value_list!(Map.get(server, "headers", []), "headers")

  defp resolve_auth(%{"type" => "oauth"} = auth, server, opts) do
    with {:ok, credential} <- auth_string(auth, "credential", server),
         {:ok, store} <- credential_store(server, opts) do
      # The descriptor's own url decides which credential may answer for it. A
      # descriptor cannot name another server's credential and be handed that
      # server's token.
      case Imp.MCP.OAuth.authorization_header(store, credential, required_string!(server, "url")) do
        {:ok, header} -> {:ok, [header]}
        {:error, reason} -> {:error, auth_unavailable(server, reason)}
      end
    end
  end

  defp resolve_auth(%{"type" => "bearer_env"} = auth, server, _opts) do
    with {:ok, variable} <- auth_string(auth, "variable", server),
         {:ok, required?} <- auth_required(auth, server) do
      case System.get_env(variable) do
        value when is_binary(value) and value != "" ->
          {:ok, [{"Authorization", "Bearer " <> value}]}

        _unset when required? ->
          {:error,
           auth_unavailable(
             server,
             "environment variable #{variable} is unset and this server declares it required"
           )}

        _unset ->
          # Some hosted MCP servers answer anonymously with lower rate limits.
          # Connecting keyless is the useful default; say so once per connection
          # so an unset key is visible without stopping the host.
          Logger.warning(
            "MCP server #{server_name(server)}: #{variable} is unset; " <>
              "connecting with no Authorization header"
          )

          {:ok, []}
      end
    end
  end

  defp resolve_auth(auth, server, _opts),
    do: {:error, auth_unavailable(server, {:unsupported_mcp_auth_type, Map.get(auth, "type")})}

  defp auth_string(auth, key, server) do
    case Map.get(auth, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _missing ->
        {:error, auth_unavailable(server, "auth #{key} must be a non-empty string")}
    end
  end

  defp auth_required(auth, server) do
    case Map.get(auth, "required", false) do
      required when is_boolean(required) ->
        {:ok, required}

      other ->
        {:error, auth_unavailable(server, {:invalid_auth_required, shape(other)})}
    end
  end

  defp credential_store(server, opts) do
    case Keyword.get(opts, :credentials) do
      %Imp.MCP.OAuth.Store{} = store ->
        {:ok, store}

      nil ->
        {:error,
         auth_unavailable(
           server,
           "oauth auth needs the :credentials option, an Imp.MCP.OAuth.store/1 value"
         )}
    end
  end

  defp auth_unavailable(server, reason),
    do: {:mcp_auth_unavailable, server_name(server), reason}

  defp client_options(server, opts, headers) do
    case server_type(server) do
      "stdio" ->
        command = required_string!(server, "command")
        args = string_list!(Map.get(server, "args", []), "args")
        env = name_value_list!(Map.get(server, "env", []), "env")

        [
          transport: :stdio,
          command: [command | args],
          cd: Keyword.get(opts, :cwd, File.cwd!()),
          env: env,
          environment_policy: :isolated,
          default_timeout: timeout(opts),
          era_probe_timeout: timeout(opts),
          handshake_timeout: timeout(opts),
          health_check_interval: nil,
          reconnect: false
        ]

      type when type in ["http", "sse"] ->
        url = required_string!(server, "url")

        [
          transport: :http,
          url: url,
          headers: headers,
          security: %{trusted_origins: [http_origin!(url)]},
          use_sse: type == "sse",
          default_timeout: timeout(opts),
          era_probe_timeout: timeout(opts),
          handshake_timeout: timeout(opts),
          health_check_interval: nil,
          reconnect: false
        ]

      type ->
        raise ArgumentError, "unsupported ACP MCP server type: #{inspect(type)}"
    end
  end

  # ACP v1's original stdio descriptor was untagged. Newer schemas include
  # `type: "stdio"`; accept both without treating arbitrary maps as stdio.
  defp server_type(%{"type" => type}) when is_binary(type), do: type
  defp server_type(%{"command" => command}) when is_binary(command), do: "stdio"
  defp server_type(_server), do: nil

  defp required_string!(server, key) do
    case Map.get(server, key) do
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError,
              "MCP server #{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp http_origin!(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default_port = if scheme == "https", do: 443, else: 80
        port = uri.port || default_port
        host = if String.contains?(host, ":"), do: "[#{host}]", else: host
        "#{scheme}://#{String.downcase(host)}:#{port}"

      _other ->
        raise ArgumentError, "MCP server url must be an absolute HTTP(S) URL"
    end
  end

  defp string_list!(values, _field) when is_list(values) and values == [], do: []

  defp string_list!(values, _field) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: values,
      else: raise(ArgumentError, "MCP server args must be strings")
  end

  defp string_list!(_values, field),
    do: raise(ArgumentError, "MCP server #{field} must be a list")

  defp name_value_list!(values, field) when is_list(values) do
    Enum.map(values, fn value ->
      value = stringify_keys(value)

      case value do
        %{"name" => name, "value" => entry} when is_binary(name) and is_binary(entry) ->
          {name, entry}

        _other ->
          raise ArgumentError, "MCP server #{field} entries require string name/value fields"
      end
    end)
  end

  defp name_value_list!(_values, field),
    do: raise(ArgumentError, "MCP server #{field} must be a list")

  defp disconnect_all(clients) do
    Enum.each(clients, fn {_server, client} ->
      if Process.alive?(client), do: safe_disconnect(client)
    end)

    :ok
  end

  defp cleanup_bridge(bridge), do: fn -> Imp.MCP.Clients.stop(bridge) end

  defp safe_disconnect(client) do
    _ = ExMCP.Client.disconnect(client)
    if Process.alive?(client), do: ExMCP.Client.stop(client)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp validate_options!(opts) do
    unknown = Keyword.keys(opts) -- @option_keys

    if unknown != [], do: raise(ArgumentError, "unknown Imp.MCP options: #{inspect(unknown)}")

    case Keyword.get(opts, :authorize) do
      nil -> :ok
      callback when is_function(callback, 1) or is_function(callback, 2) -> :ok
      _other -> raise ArgumentError, ":authorize must be a function of arity 1 or 2"
    end

    case Keyword.fetch(opts, :owner) do
      :error -> :ok
      {:ok, owner} when is_pid(owner) -> :ok
      {:ok, _other} -> raise ArgumentError, ":owner must be a pid"
    end

    unless is_list(Keyword.get(opts, :trusted_servers, [])) do
      raise ArgumentError, ":trusted_servers must be a list of exact server maps"
    end

    case Keyword.get(opts, :credentials) do
      nil ->
        :ok

      %Imp.MCP.OAuth.Store{} ->
        :ok

      _other ->
        raise ArgumentError,
              ":credentials must be an Imp.MCP.OAuth.Store from Imp.MCP.OAuth.store/1"
    end

    reserved_tool_names = Keyword.get(opts, :reserved_tool_names, [])

    unless is_list(reserved_tool_names) and
             Enum.all?(reserved_tool_names, fn name -> is_atom(name) or is_binary(name) end) do
      raise ArgumentError, ":reserved_tool_names must be a list of atom or string names"
    end

    unless result_mode(opts) in [:text, :structured] do
      raise ArgumentError, ":result_mode must be :text or :structured"
    end

    unless Keyword.get(opts, :on_failure, :refuse) in [:refuse, :drop] do
      raise ArgumentError, ":on_failure must be :refuse or :drop"
    end

    unless is_integer(timeout(opts)) and timeout(opts) > 0 do
      raise ArgumentError, ":timeout must be a positive integer"
    end
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 30_000)
  defp result_mode(opts), do: Keyword.get(opts, :result_mode, :text)

  defp server_name(server), do: Map.get(server, "name", "unnamed")

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(value), do: value

  defp shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
