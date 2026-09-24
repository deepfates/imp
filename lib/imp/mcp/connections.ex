defmodule Imp.MCP.Import do
  @moduledoc """
  An owned remote tool catalog; cleanup closes its connections.

  `unavailable` is empty unless the import ran with `on_failure: :drop`, in
  which case it holds one `%{server: name, index: index, reason: reason}` entry
  per server that was left out. The tools of every server that did connect are
  in `tools`.

  `index` is the position of the dropped descriptor in the list given to
  `import_tools/2`, and it is the only thing in the entry that identifies which
  descriptor was left out. A name does not: names are not required to be unique,
  and a descriptor with no `"name"` is reported as `"unnamed"`. `server` is for
  the message an operator reads; `index` is for the caller deciding which of its
  own descriptors is now absent.

  What is left out changes nothing about what the tools beside it are called:
  names come from the declaration. See "What a tool is named" in
  `Imp.MCP.Connections`.
  """
  defstruct tools: [], annotations: %{}, provenance: %{}, cleanup: nil, unavailable: []

  @type absence :: %{server: String.t(), index: non_neg_integer(), reason: term()}

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

  ## Descriptors

  A server is a map with string keys. A local server runs as a child process
  that speaks MCP on stdin and stdout:

      %{
        "name" => "files",
        "type" => "stdio",
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        "env" => [%{"name" => "LOG_LEVEL", "value" => "warn"}]
      }

  `"type"` may be left out when `"command"` is present. The command is found on
  `PATH` and runs in `:cwd` (the current directory by default). It sees the
  host's ordinary variables (`HOME`, `PATH`, `LANG` and the like) and its own
  `"env"`, not the rest of the host's environment. Closing the import, or the
  end of its `:owner`, stops the server and every process it started.

  A remote server is `"type" => "http"` (Streamable HTTP) or `"sse"`, with a
  `"url"`:

      %{"name" => "docs", "type" => "http", "url" => "https://mcp.example.com/mcp"}

  Only descriptors the caller authorized are dialed. `trusted_servers:` lists
  them exactly; `authorize:` is a function of the descriptor (and optionally
  a `%{cwd: cwd, server: descriptor}` context) that returns `:ok` or `true` to
  allow it; anything else refuses it:

      {:ok, import} = Imp.MCP.connect([server], trusted_servers: [server])
      tool = Enum.find(import.tools, &(to_string(&1.name) == "read_text_file"))
      Imp.Tool.call(tool, %{"path" => "/tmp/notes.txt"})
      import.cleanup.()

  ## Authenticating an HTTP server

  A descriptor may carry static `"headers"`. It may instead name an auth kind,
  which is resolved to a header when the connection is built and never written
  back into the descriptor:

      %{"type" => "oauth", "credential" => "readwise"}

  resolves through the `Imp.MCP.OAuth.Store` passed as the `:credentials`
  option, refreshing the grant when it is near expiry. The credential must have
  been authorized for this descriptor's `"url"`; naming another server's
  credential is refused rather than resolved. See `Imp.MCP.OAuth`.

      %{"type" => "bearer_env", "variable" => "EXA_API_KEY"}

  reads the variable from the host's environment. When it is unset the server
  is connected with no `Authorization` header and one warning naming the server
  and the variable is logged, so a server that also answers anonymously still
  works. Add `"required" => true` to refuse the connection instead, with a
  message naming the variable.

  Both forms may be combined with static `"headers"`; the resolved header is
  appended. Tokens never appear in the descriptor, so authorization callbacks,
  `:call_meta` and tool provenance never see one.

  ## A server that cannot be reached

  Under the default `on_failure: :refuse`, one unreachable server fails the
  whole import: every client is disconnected and an error is returned.

  Under `on_failure: :drop`, a server whose transport or `initialize` fails,
  which never answers at all, or which cannot answer `tools/list`, is left out:
  its client is closed, the servers beside it keep their tools, and the
  returned `Imp.MCP.Import` names it in `unavailable` with the reason the
  refusal would have carried, summarized to one short line, and with the
  `index` of the descriptor in the list that was passed in. Use it for a caller
  whose servers are independent, such as a long-lived agent holding several
  third-party catalogs.

  Each dial is bounded by `:timeout` on its own, so a host that accepts the
  connection and then answers nothing costs that server its timeout and no more.

  ## Calls to one server at once

  `pool_size:` (1 by default) is how many connections Imp opens to each
  `http` or `sse` server. An ExMCP client sends one HTTP request at a time,
  making the POST from inside its own process, so a quick call made while a
  slow one is out on the same connection waits for the slow one to answer.
  With a pool each tool call borrows an idle connection for the length of the
  call, so up to `pool_size` calls to one server run at once. A host sets it
  from how many of its own calls can be out together. A call that finds every
  connection busy waits for one, and if none comes free within `:timeout` it
  fails as `:not_sent` (`Imp.MCP.CallFailure`): nothing was sent.

  The first connection to a server decides whether the server is reachable and
  lists its tools. The others are dialed at once, the way the first connected,
  so a server costs the import at most about three `:timeout`s (the first
  dial, a second one with the standard handshake only when a server refuses
  ExMCP's opening probe, and the extras) whatever `pool_size` is. Each holds the server's origin in the trusted origins for as
  long as it lives, and one that cannot be opened leaves the server with fewer
  connections and is logged.

  A connection whose call timed out, or whose caller died during the call, may
  still be waiting on that request inside ExMCP, and lent again it would hold
  the next call behind it. It is taken out of the pool instead and closed once
  that request is done, so the server finishes what it was doing, and a
  replacement is dialed in the background; calls wait for it. A replacement that cannot be dialed
  leaves the server a connection fewer, and a server left with none answers
  its calls `:not_sent` with `reason: :not_connected`.

  A `stdio` server has one connection whatever `pool_size` says. ExMCP writes
  each request to its pipe and matches answers by id, so calls to it already
  run at once over that connection, and they go straight to it. A second
  connection would be a second server process with state of its own.

  ## What a tool is named

  The declaration decides, and nothing else. A descriptor may carry a
  `"tool_prefix"`:

      %{"name" => "exa", "type" => "http", "url" => "…", "tool_prefix" => "exa_"}

  Every tool that server offers is then named `exa_` <> its own name, always,
  whether or not anything else is connected. A descriptor without a prefix
  contributes its tools under the names the server gave them. A name therefore
  never depends on which servers answered.

  Nothing is renamed to resolve anything. If two connected servers without
  prefixes offer the same tool name, the import refuses with
  `{:mcp_tool_name_collision, tool, servers}` naming the tool and both servers,
  and logs the fix — give one of them a `"tool_prefix"`. A tool whose name is
  one the program has already taken (`:reserved_tool_names`) is refused the
  same way. Both refusals stand under `on_failure: :drop`, which drops what the
  network did and never what the caller declared.

  A consequence to plan for: a collision between two unprefixed servers goes
  unnoticed for as long as one of them is absent, and then refuses the import
  the first time both answer.

  `Imp.Tool` provenance (`tool.metadata.mcp`) carries the server and the name
  the server published, whatever the tool ended up called.

  Dropping covers failures of the connection and of `tools/list`, not of the
  declaration. A descriptor that `:authorize` refused, one whose `auth` cannot
  produce a header (a `bearer_env` variable declared `required` and unset, for
  example), one whose `"tool_prefix"` is not a string, one that is malformed, a
  tool name two servers both claim, and anything raised by the caller's own
  `:tool_filter` all refuse the import under either setting.
  """

  require Logger

  alias Imp.MCP.{CallFailure, Import}

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
    :on_failure,
    :pool_size
  ]

  # ExMCP 1.5.0's own defaults for an HTTP connection, set explicitly so the
  # bound on a request can be read from the options it was dialed with.
  @http_dns_timeout 1_000
  @http_connect_timeout 5_000
  @http_request_timeout 30_000

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
      # Internal: the tools borrow their connections from the bridge.
      opts = Keyword.put(opts, :bridge, bridge)

      case connect_isolated(servers, opts) do
        {:ok, connected, unavailable} ->
          case tools_from_clients(connected, opts) do
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

  # ExMCP may exit the connector on a bad handshake, so connecting happens in a
  # helper process and the surviving clients are adopted onto the owner-owned
  # bridge afterwards. The :owner outlives a failed handshake either way.
  defp connect_isolated(servers, opts) do
    parent = self()
    ref = make_ref()
    # Every dial is bounded on its own inside `dial/2`. This budget is only the
    # backstop for the helper itself wedging around them, so it has to cover the
    # whole list dialed in turn: per server the first dial, the one retry
    # `dial_http_fallback/2` may make, and the extra dials, which run at once.
    timeout = timeout(opts) * 3 * max(length(servers), 1) + 5_000

    {pid, mon} =
      spawn_monitor(fn ->
        # Two deaths reach this process as exit signals: a client whose
        # transport refuses the connection exits after answering
        # `ExMCP.Client.start_link/1`, and a dial abandoned at its deadline is
        # killed while linked here. Without this flag either one kills the
        # helper, losing the reason and every server after the failing one.
        Process.flag(:trap_exit, true)

        result =
          try do
            connect_all(servers, opts, 0, [], [])
          catch
            kind, reason -> {:error, {:mcp_connection_failed, {kind, reason}}, []}
          end

        # The helper hands its clients to the bridge itself, and lets go of
        # them only once the bridge holds them, so at no moment does nothing
        # hold them. The caller may die, or give up at the time limit below,
        # after the helper has answered; the bridge then closes them with its
        # owner or with the import, and a bridge already gone means they are
        # closed here.
        case result do
          {:ok, clients, unavailable} ->
            try do
              :ok =
                Imp.MCP.Clients.adopt(
                  Keyword.fetch!(opts, :bridge),
                  client_entries(clients),
                  replacements(clients, opts)
                )

              unlink_all(clients)
              send(parent, {ref, {:ok, clients, unavailable}})
            catch
              :exit, reason ->
                disconnect_all(clients)
                send(parent, {ref, {:error, {:mcp_import_exit, reason}}})
            end

          {:error, reason, clients} ->
            disconnect_all(clients)
            send(parent, {ref, {:error, reason}})
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
        abandon(pid)
        Process.demonitor(mon, [:flush])

        # An answer that arrived with the time limit names clients the bridge
        # already holds; the caller stops the bridge, which closes them.
        receive do
          {^ref, _result} -> :ok
        after
          0 -> :ok
        end

        {:error, :mcp_import_timeout}
    end
  end

  defp unlink_all(clients) do
    Enum.each(clients, fn {_index, _server, pooled, _options} ->
      Enum.each(pooled, &if(Process.alive?(&1), do: Process.unlink(&1)))
    end)
  end

  # Killing a process that opened MCP clients does not close them: an
  # `ExMCP.Client` traps exits and its catch-all `handle_info/2` swallows the
  # `EXIT` from the process that started it, so an abandoned dial's clients
  # would stay alive holding their sockets. A client whose `start_link/1` has
  # not returned has no pid anybody holds, so the links are the only handle on
  # it and must be read before the kill. The chain is at most
  # helper -> dial -> client -> transport and every link in it was opened by
  # this import. A helper abandoned while handing its clients to the bridge
  # reaches the bridge through them; that bridge is this import's own, and the
  # caller stops it on the time limit anyway.
  defp abandon(pid), do: abandon(pid, 3)

  defp abandon(pid, depth) do
    # Links hold ports as well as pids — a client's socket is one — and a port
    # dies with the process that owns it, so only the pids are followed.
    links =
      case Process.info(pid, :links) do
        {:links, links} -> Enum.filter(links, &(is_pid(&1) and &1 != self()))
        nil -> []
      end

    Process.exit(pid, :kill)

    if depth > 0,
      do: Enum.each(links, &abandon(&1, depth - 1)),
      else: Enum.each(links, &Process.exit(&1, :kill))

    :ok
  end

  defp connect_all([], _opts, _index, clients, unavailable),
    do: {:ok, Enum.reverse(clients), Enum.reverse(unavailable)}

  defp connect_all([server | rest], opts, index, clients, unavailable) when is_map(server) do
    server = stringify_keys(server)

    # Authorization and header resolution are separated from the dial because
    # only the dial is droppable: the first two are answers the caller already
    # gave, and `client_options/3` raises on a descriptor nobody can address.
    with :ok <- validate_tool_prefix(server),
         :ok <- authorize(server, opts),
         {:ok, headers} <- connection_headers(server, opts),
         options = client_options(server, opts, headers),
         :ok <- trust(options, self()),
         {:ok, client, options} <- dial_http_fallback(options, timeout(opts)),
         :ok <- trust(options, client) do
      pooled = [client | dial_more(options, server, extra_connections(server, opts), opts)]
      connected = {index, server, pooled, options}
      connect_all(rest, opts, index + 1, [connected | clients], unavailable)
    else
      {:unreachable, reason} ->
        if drop?(opts) do
          connect_all(rest, opts, index + 1, clients, [
            absence(server, index, reason) | unavailable
          ])
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

  defp connect_all([server | _rest], _opts, _index, clients, _unavailable),
    do: {:error, {:invalid_mcp_server, shape(server)}, clients}

  # One dial, bounded on its own. `ExMCP.Client.start_link/1` returns only when
  # the handshake has finished, and a host that accepts the connection and then
  # answers nothing — a firewall dropping packets, a wedged proxy — returns
  # within neither `:handshake_timeout` nor `:era_probe_timeout` on this path.
  # The bound here is what keeps silence costing one server rather than the
  # whole import.
  #
  # A failed dial leaves nothing behind: `start_link/1` answers with an error
  # only after the client process has exited. A dial abandoned at the deadline
  # is killed along with the half-open client it is still linked to, which does
  # not die of the link alone (see `abandon/1`).
  defp dial(options, deadline) do
    options |> start_dial() |> await_dial(System.monotonic_time(:millisecond) + deadline)
  end

  # Linked, not detached: a dial left running when the import helper above is
  # abandoned would hold a client and a socket that nobody holds a pid for.
  # The dial process keeps its link to the client until the process awaiting
  # it has linked the client too, so the client is linked to one of them at
  # every moment and `abandon/1` finds it through either. Several dials can be
  # out at once; one whose answer waits in the mailbox still holds its client.
  defp start_dial(options) do
    parent = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        # The client exits when its transport refuses, and this process has to
        # survive that to report the reason.
        Process.flag(:trap_exit, true)

        outcome =
          try do
            case ExMCP.Client.start_link(options) do
              {:ok, client} -> {:ok, client}
              {:error, reason} -> {:unreachable, {:mcp_connection_failed, reason}}
            end
          catch
            kind, reason -> {:unreachable, {:mcp_connection_failed, {kind, reason}}}
          end

        send(parent, {ref, outcome})

        with {:ok, client} <- outcome do
          receive do
            {^ref, :taken} ->
              Process.unlink(client)

            # The process awaiting this dial is gone: nobody will take the
            # client, and it does not die of the link alone.
            {:EXIT, ^parent, _reason} ->
              Process.exit(client, :kill)
          end
        end
      end)

    {pid, Process.monitor(pid), ref}
  end

  defp await_dial({pid, mon, ref}, deadline_at) do
    receive do
      {^ref, {:ok, client} = outcome} ->
        Process.demonitor(mon, [:flush])
        # This process traps exits, so a client already gone arrives as an
        # `EXIT` here rather than raising.
        Process.link(client)
        send(pid, {ref, :taken})
        outcome

      {^ref, outcome} ->
        Process.demonitor(mon, [:flush])
        outcome

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:unreachable, {:mcp_connection_failed, {:exit, reason}}}
    after
      max(deadline_at - System.monotonic_time(:millisecond), 0) ->
        # The dial process is still linked to its client, whether the client
        # is half-open or finished between the deadline and this kill.
        abandon(pid)
        Process.demonitor(mon, [:flush])

        receive do
          {^ref, _outcome} -> :ok
        after
          0 -> :ok
        end

        {:unreachable, {:mcp_connection_failed, :timeout}}
    end
  end

  # An authorized remote server's origin is trusted while this helper dials it
  # and then for as long as its client lives. See `Imp.MCP.Trust`.
  defp trust(options, holder) do
    case Keyword.get(options, :url) do
      nil -> :ok
      url -> Imp.MCP.Trust.hold(http_origin!(url), holder)
    end
  end

  # ExMCP opens an HTTP connection with a `server/discover` probe and falls back
  # to the standard `initialize` only when the probe fails with a JSON-RPC error
  # or an HTTP 400. Public servers that do not know the probe answer it with
  # other 4xx statuses (Scry answers 404), and the connection then fails without
  # `initialize` ever being sent. One more dial asks for the standard handshake
  # only. A 401 is reported as `:unauthorized`, not as an HTTP error, and is not
  # retried: it is about credentials, not the protocol. ExMCP reports this
  # failure as a string, so the status is read from its text. This retires if
  # ExMCP falls back on any 4xx to the probe. The options that connected are
  # returned with the client, so further connections to the server are dialed
  # the way that worked.
  defp dial_http_fallback(options, deadline) do
    case dial(options, deadline) do
      {:ok, client} ->
        {:ok, client, options}

      {:unreachable, {:mcp_connection_failed, reason}} = failed ->
        if Keyword.get(options, :transport) == :http and probe_refused?(reason) do
          legacy = Keyword.put(options, :protocol_mode, :legacy_only)

          with {:ok, client} <- dial(legacy, deadline), do: {:ok, client, legacy}
        else
          failed
        end

      failed ->
        failed
    end
  end

  defp probe_refused?(reason),
    do: inspect(reason, limit: :infinity) =~ ~r/era_probe_failed.*\{:http_error, 4\d\d\b/

  # The connections past the first. The first already showed the server is
  # there, so one of these that cannot be opened costs the server a connection
  # rather than its place in the import.
  # Each is dialed with the options the first connected with, and holds its
  # server's origin in `Imp.MCP.Trust` for as long as it lives.
  defp dial_more(_options, _server, count, _opts) when count <= 0, do: []

  defp dial_more(options, server, count, opts) do
    # All at once, each bounded by the same deadline, so extras that never
    # answer cost the server one `:timeout` rather than one each.
    deadline_at = System.monotonic_time(:millisecond) + timeout(opts)

    1..count
    |> Enum.map(fn _ -> start_dial(options) end)
    |> Enum.flat_map(fn dialing ->
      case await_dial(dialing, deadline_at) do
        {:ok, client} ->
          :ok = trust(options, client)
          [client]

        {:unreachable, reason} ->
          Logger.warning(
            "MCP server #{inspect(server_name(server))} took one connection fewer than " <>
              "pool_size asked for: #{inspect(shorten(reason))}"
          )

          []
      end
    end)
  end

  # A pooled connection whose call timed out, or whose borrower died, may
  # still be waiting on that request inside ExMCP, so the bridge closes it and
  # asks for another in its place. The replacement is dialed the way the first
  # connection connected. The bridge's dialing process holds the origin in the
  # trusted origins before the retired client, which held it, is closed, and
  # the replacement holds it for its own life after.
  #
  # Each comes with how long a retired connection is given to finish the
  # request it is inside before it is killed: longer than that request can
  # take as the connection bounds it.
  defp replacements(connected, opts) do
    for {index, server, _pooled, options} <- connected, pooled?(server), into: %{} do
      {index, {redial(server, options, opts), request_bound(options) + 1_000}}
    end
  end

  defp request_bound(options) do
    Keyword.fetch!(options, :dns_timeout_ms) + Keyword.fetch!(options, :timeout) +
      Keyword.fetch!(options, :request_timeout)
  end

  defp redial(server, options, opts) do
    fn close_retired ->
      :ok = trust(options, self())
      close_retired.()

      with {:ok, client} <- dial(options, timeout(opts)),
           :ok <- trust(options, client) do
        {:ok, client}
      else
        {:unreachable, reason} ->
          Logger.warning(
            "MCP server #{inspect(server_name(server))} lost a connection that could " <>
              "not be replaced: #{inspect(shorten(reason))}"
          )

          {:error, reason}
      end
    end
  end

  # Each connection is lent by the bridge under its server's place in the list.
  defp client_entries(connected),
    do:
      Enum.flat_map(connected, fn {index, _server, pooled, _options} ->
        Enum.map(pooled, &{index, &1})
      end)

  defp tools_from_clients(clients, opts) do
    clients
    |> Enum.reduce_while({:ok, [], []}, fn {index, server, [client | _] = pooled, _options},
                                           {:ok, acc, unavailable} ->
      case server_tools(index, server, client, opts) do
        {:ok, sourced} ->
          {:cont, {:ok, acc ++ sourced, unavailable}}

        {:error, reason} ->
          if drop?(opts) do
            # This one answered the handshake and then could not say what it
            # offers, so it contributes nothing. Close it here: an open client
            # nothing imported from would otherwise live as long as the import.
            Enum.each(pooled, &safe_disconnect/1)
            {:cont, {:ok, acc, [absence(server, index, reason) | unavailable]}}
          else
            {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, sourced_schemas, unavailable} ->
        with {:ok, schemas} <- name_tools(sourced_schemas, opts) do
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

  # `{:mcp_tools_list_failed, server, reason}` is the only error this returns,
  # and it covers everything the server got wrong about its own catalog,
  # including a `tools/list` body that is not a catalog. That keeps `:drop`
  # exactly aligned with server-side catalog failures: a dropped server's
  # reason always names the server and is never a fault of the caller's that
  # happened to surface here. Failures after the catalog — the caller's own
  # `:tool_filter` raising, for one — are left to the caller's error paths.
  defp server_tools(index, server, client, opts) do
    case list_tools(client, opts) do
      {:ok, response} ->
        case tool_schemas(response) do
          {:ok, schemas} -> attach_client_runs(schemas, index, client, server, opts)
          {:error, reason} -> {:error, {:mcp_tools_list_failed, server_name(server), reason}}
        end

      {:error, reason} ->
        {:error, {:mcp_tools_list_failed, server_name(server), reason}}
    end
  end

  defp list_tools(client, opts) do
    ExMCP.Client.list_tools(client, format: :map, timeout: timeout(opts))
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp drop?(opts), do: Keyword.get(opts, :on_failure, :refuse) == :drop

  # What the import says about a server it left out. The reason is the term the
  # refusal would have carried, with its detail summarized: a transport error
  # arrives as a nested struct whose inspection runs to several lines, and this
  # is read in a log line and an operator's report.
  defp absence(server, index, reason),
    do: %{server: server_name(server), index: index, reason: shorten(reason)}

  defp shorten({tag, detail}) when is_atom(tag), do: {tag, summary(detail)}

  defp shorten({tag, name, detail}) when is_atom(tag) and is_binary(name),
    do: {tag, name, summary(detail)}

  defp shorten(reason), do: reason

  defp summary(detail) when is_atom(detail), do: detail

  # A JSON-RPC error is a map whose "message" is the server's own sentence
  # about what went wrong, and that sentence is the half worth reading:
  # inspecting the map puts a code and a data blob in front of it and then
  # truncates it away.
  defp summary(%{"message" => message}) when is_binary(message), do: summary(message)

  # A sentence is read as one, not as an inspected string in quotation marks.
  defp summary(detail) when is_binary(detail), do: bounded(detail)

  defp summary(detail) do
    if is_exception(detail),
      do: bounded(Exception.message(detail)),
      else: bounded(inspect(detail, limit: 3, printable_limit: 120))
  end

  defp bounded(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > 120, do: String.slice(text, 0, 119) <> "…", else: text
  end

  defp attach_client_runs(schemas, index, client, server, opts) do
    bridge = Keyword.fetch!(opts, :bridge)
    pooled? = pooled?(server)

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

        Map.put(schema, "run", fn
          arguments when not pooled? ->
            call_tool(client, name, arguments, server, opts)

          arguments ->
            borrowed_call(bridge, index, name, arguments, server, opts)
        end)
      end)

    {:ok, Enum.map(schemas, &{server, &1})}
  end

  defp borrowed_call(bridge, index, name, arguments, server, opts) do
    case Imp.MCP.Clients.checkout(bridge, index, timeout(opts)) do
      {:ok, client} ->
        result =
          try do
            call_tool(client, name, arguments, server, opts)
          catch
            kind, reason ->
              Imp.MCP.Clients.retire(bridge, client)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        # A call its caller stopped waiting for is still out inside ExMCP's
        # client, which sends one request at a time: lent again, the client
        # would hold the next call behind it.
        if still_out?(result),
          do: Imp.MCP.Clients.retire(bridge, client),
          else: Imp.MCP.Clients.checkin(bridge, client)

        result

      {:error, reason} ->
        {:error, CallFailure.returned(server_name(server), name, reason)}
    end
  end

  defp still_out?({:error, %CallFailure{reason: :timeout}}), do: true
  defp still_out?({:error, %CallFailure{reason: {:exit, {:timeout, _call}}}}), do: true
  defp still_out?(_result), do: false

  defp call_tool(client, name, arguments, server, opts) do
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
      {:ok, result} ->
        Imp.MCP.tool_result(result, result_mode(opts))

      {:error, reason} ->
        {:error, CallFailure.returned(server_name(server), name, reason)}
    end
  catch
    :exit, reason -> {:error, CallFailure.exited(server_name(server), name, reason)}
  end

  defp call_meta(server, opts) do
    case Keyword.get(opts, :call_meta) do
      nil -> %{}
      callback -> callback.(server)
    end
  end

  # MCP tool names are scoped to one server, while an Imp program consumes one
  # flat catalog. What a tool is called here is the caller's declaration and
  # nothing else: a descriptor's `"tool_prefix"` is prepended to every tool that
  # server offers, and a descriptor without one contributes its tools under the
  # names the server gave them. Nothing is renamed to resolve a collision, so a
  # name never depends on which servers answered.
  defp name_tools(sourced_schemas, opts) do
    reserved = opts |> Keyword.get(:reserved_tool_names, []) |> MapSet.new(&to_string/1)

    named =
      Enum.map(sourced_schemas, fn {server, schema} ->
        original = schema |> Map.get("name") |> to_string()
        name = server |> tool_prefix() |> Kernel.<>(original)
        {server_name(server), original, prefixed_schema(schema, server, original, name)}
      end)

    with :ok <- refuse_duplicate_names(named),
         :ok <- refuse_reserved_names(named, reserved) do
      {:ok, Enum.map(named, fn {_server, _original, schema} -> schema end)}
    end
  end

  # A name the server gave is left exactly as it is, description included. A
  # prefixed one says where it came from, because the name the model sees is no
  # longer the name the server published.
  defp prefixed_schema(schema, _server, original, name) when name == original, do: schema

  defp prefixed_schema(schema, server, original, name) do
    server_name = server_name(server)

    schema
    |> Map.put("name", name)
    |> Map.update(
      "description",
      "MCP tool #{original} from #{server_name}",
      &qualified_tool_description(&1, server_name, original)
    )
  end

  # Two servers offering one name is a defect in the declaration, so it refuses
  # the import, under `on_failure: :drop` too. The error names the tool and
  # every server that offered it; the log names the fix, because a term cannot
  # carry a sentence.
  defp refuse_duplicate_names(named) do
    named
    |> Enum.group_by(fn {_server, _original, schema} -> schema["name"] end)
    |> Enum.find(fn {_name, entries} -> length(entries) > 1 end)
    |> case do
      nil ->
        :ok

      {name, entries} ->
        servers = Enum.map(entries, fn {server, _original, _schema} -> server end)

        Logger.error(
          "MCP tool #{inspect(name)} is offered by #{Enum.join(servers, " and ")}; " <>
            "give one of them a \"tool_prefix\" in its descriptor"
        )

        {:error, {:mcp_tool_name_collision, name, servers}}
    end
  end

  # The same refusal against the names the program has already taken. A server
  # whose `"tool_prefix"` moves its tool off the reserved name is no collision:
  # the check is on the name the program will see.
  defp refuse_reserved_names(named, reserved) do
    named
    |> Enum.filter(fn {_server, _original, schema} ->
      MapSet.member?(reserved, schema["name"])
    end)
    |> case do
      [] ->
        :ok

      entries ->
        {_server, _original, schema} = hd(entries)
        name = schema["name"]
        servers = Enum.map(entries, fn {server, _original, _schema} -> server end)

        Logger.error(
          "MCP tool #{inspect(name)} from #{Enum.join(servers, " and ")} is a name this " <>
            "program reserves; give that server a \"tool_prefix\" in its descriptor"
        )

        {:error, {:mcp_tool_name_collision, name, servers}}
    end
  end

  # Declared, never derived. An absent or empty prefix means the server's own
  # names; anything that is not a string is a declaration this cannot act on and
  # is refused before anything is dialed (`validate_tool_prefix/1`).
  defp tool_prefix(server) do
    case Map.get(server, "tool_prefix") do
      prefix when is_binary(prefix) -> prefix
      _absent -> ""
    end
  end

  defp validate_tool_prefix(server) do
    case Map.get(server, "tool_prefix") do
      nil -> :ok
      prefix when is_binary(prefix) -> :ok
      other -> {:error, {:invalid_tool_prefix, server_name(server), shape(other)}}
    end
  end

  # The tool declares its own nature in `annotations`; MCP carries that in
  # `tools/list` alongside the schema. Key it by the name the program will see,
  # which is the prefixed name whenever the descriptor declares a prefix.
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
          # Owns the server's process group; see `Imp.MCP.OwnedStdio`.
          transport: Imp.MCP.OwnedStdio,
          command: [command | args],
          cd: Keyword.get(opts, :cwd, File.cwd!()),
          env: env,
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
          # ExMCP sends the server's own origin back to it as `Origin` unless
          # told otherwise. A client that is not a browser has no origin to
          # assert, and a server that allow-lists browser origins refuses it
          # (Scry answers 403). No `Origin` header is sent.
          security: %{origin: nil},
          use_sse: type == "sse",
          # ExMCP bounds each HTTP request by these, apart from how long the
          # caller waits: resolving the name, connecting (ExMCP reads the
          # connect bound from `:timeout`, which is also the client's wait for
          # a request made without one; Imp passes one on every request), and
          # the request itself. The request bound is the host's `:timeout`, so
          # a call it allows is not cut off by ExMCP's own 30 s default, and
          # never less than that default: a request its caller stopped waiting
          # for is left to finish on the server (see `Imp.MCP.Clients`).
          dns_timeout_ms: @http_dns_timeout,
          timeout: @http_connect_timeout,
          request_timeout: max(timeout(opts), @http_request_timeout),
          era_probe_timeout: timeout(opts),
          handshake_timeout: timeout(opts),
          health_check_interval: nil,
          reconnect: false
        ] ++ root_endpoint(url)

      type ->
        raise ArgumentError, "unsupported ACP MCP server type: #{inspect(type)}"
    end
  end

  # A URL whose path is `/` names a server that answers at its root (Scry
  # answers `initialize` on `POST https://mcp.scry.io/`). ExMCP reads a `/`
  # path as no path and posts to `/mcp/v1`; an empty endpoint keeps the root.
  # This retires if ExMCP treats a written `/` as a path.
  defp root_endpoint(url) do
    case URI.parse(url) do
      %URI{path: "/"} -> [endpoint: ""]
      _other -> []
    end
  end

  # A stdio descriptor is either tagged `type: "stdio"` or untagged and
  # identified by its `"command"`. Both are accepted; an arbitrary map is not
  # treated as stdio.
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
    Enum.each(clients, fn {_index, _server, pooled, _options} ->
      Enum.each(pooled, &if(Process.alive?(&1), do: safe_disconnect(&1)))
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

    unless is_integer(pool_size(opts)) and pool_size(opts) > 0 do
      raise ArgumentError, ":pool_size must be a positive integer"
    end
  end

  defp pool_size(opts), do: Keyword.get(opts, :pool_size, 1)

  # Only HTTP connections are pooled; see "Calls to one server at once".
  defp extra_connections(server, opts),
    do: if(pooled?(server), do: pool_size(opts) - 1, else: 0)

  defp pooled?(server), do: server_type(server) in ["http", "sse"]

  defp timeout(opts), do: Keyword.get(opts, :timeout, 30_000)
  defp result_mode(opts), do: Keyword.get(opts, :result_mode, :text)

  # Always a string: this is printed in a log line and carried in a reason term
  # and in tool provenance, all of which are declared to hold one.
  defp server_name(server) do
    case Map.get(server, "name") do
      name when is_binary(name) -> name
      nil -> "unnamed"
      other -> inspect(other)
    end
  end

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
