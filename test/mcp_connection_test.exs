defmodule Imp.MCPConnectionTest do
  use ExUnit.Case, async: false

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  @moduletag capture_log: true

  defmodule Server do
    use ExMCP.Server.Handler
    use ExMCP.Server.DSL, name: "import-fixture", version: "1"

    tool "look", "Observe the fixture" do
      annotations(%{readOnlyHint: true, openWorldHint: false})
      run(fn _args, state -> {:ok, "observed", state} end)
    end
  end

  defmodule FailureServer do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    def handle_list_tools(_cursor, state),
      do:
        {:ok,
         [
           %{
             "name" => "publish",
             "description" => "Publish once",
             "inputSchema" => %{"type" => "object"}
           }
         ], nil, state}

    def handle_call_tool("publish", _, state) do
      send(Process.whereis(:mcp_failure_probe), :publication_attempt)

      {:ok,
       %{
         "isError" => true,
         "content" => [%{"type" => "text", "text" => "Outcome unknown; reconcile before retry"}],
         "structuredContent" => %{"code" => "indeterminate", "operation_id" => "receipt-123"}
       }, state}
    end
  end

  defmodule BrokenServer do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    def handle_list_tools(_cursor, state),
      do:
        {:ok,
         [
           %{
             "name" => "publish",
             "description" => "Publish once",
             "inputSchema" => %{"type" => "object"}
           }
         ], nil, state}

    def handle_call_tool("publish", _, _state) do
      send(Process.whereis(:mcp_failure_probe), :broken_attempt)
      context = ExMCP.Server.Context.current()
      :ok = ExMCP.Server.Context.report_progress(1, 2, "effect accepted")
      Process.exit(context.notification_target, :kill)
      Process.sleep(:infinity)
    end
  end

  # A catalog that overlaps with nothing in `Server`, for the declaration whose
  # servers happen not to collide.
  defmodule OtherServer do
    use ExMCP.Server.Handler
    use ExMCP.Server.DSL, name: "other-fixture", version: "1"

    tool "listen", "Listen to the fixture" do
      annotations(%{readOnlyHint: true, openWorldHint: false})
      run(fn _args, state -> {:ok, "heard", state} end)
    end
  end

  defmodule UnlistableServer do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    # Answers the handshake and then refuses to say what it offers.
    def handle_list_tools(_cursor, state), do: {:error, "catalog is being rebuilt", state}
  end

  defp server(name) do
    {descriptor, _stop} = stoppable_server(name, Server)
    descriptor
  end

  # The same fixture with a handle on its shutdown, for a test that needs one
  # declared server to stop answering between two imports of the same list.
  # Safe to call twice: `on_exit` calls it again.
  defp stoppable_server(name, handler) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}
    {:ok, _pid} = handler.start_link(transport: :http, port: port, ranch_ref: ref, use_sse: false)

    stop = fn ->
      try do
        _ = Plug.Cowboy.shutdown(ref)
        :ok
      catch
        _kind, _reason -> :ok
      end
    end

    on_exit(stop)
    {%{"name" => name, "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"}, stop}
  end

  # The defect this falsifies: the name a tool executed under was decided by
  # frequency over the catalogs that answered, so a server that failed renamed
  # the tools of the servers that did not. With `on_failure: :drop` that is not
  # a tidiness problem: everything that addresses a tool by name -- an allowance,
  # a stored record of what an agent may do, the demonstrations in its own
  # prompt -- moved on the morning a neighbour went down.
  #
  # Two imports of the SAME descriptor list are what show it, so the list is
  # built once and the second server is stopped between them.
  test "a prefixed server's tools keep their names when the server beside it is silent" do
    {two, stop_two} = stoppable_server("two", Server)
    servers = [Map.put(server("one"), "tool_prefix", "one_"), two]

    assert {:ok, up} = Imp.MCP.connect(servers, trusted_servers: servers)
    assert Enum.sort(Enum.map(up.tools, &to_string(&1.name))) == ["look", "one_look"]
    assert :ok = up.cleanup.()

    stop_two.()

    assert {:ok, down} =
             Imp.MCP.connect(servers,
               trusted_servers: servers,
               on_failure: :drop,
               timeout: 1_000
             )

    on_exit(down.cleanup)

    # The same list, one server short. The prefix is declared, so the tool that
    # is there is named exactly as it was, and the one that is not contributes
    # no name at all.
    assert Enum.map(down.tools, &to_string(&1.name)) == ["one_look"]
    assert [%{server: "two", index: 1}] = down.unavailable
    assert Imp.Tool.call(hd(down.tools), %{}) == "observed"
  end

  # The same stability without any prefix, where the catalogs do not overlap.
  # Nothing is added to these names when the neighbour answers and nothing is
  # taken off when it does not.
  test "two unprefixed servers whose catalogs do not overlap keep their own names" do
    {other, stop_other} = stoppable_server("other", OtherServer)
    servers = [server("one"), other]

    assert {:ok, up} = Imp.MCP.connect(servers, trusted_servers: servers)
    assert Enum.sort(Enum.map(up.tools, &to_string(&1.name))) == ["listen", "look"]
    assert :ok = up.cleanup.()

    stop_other.()

    assert {:ok, down} =
             Imp.MCP.connect(servers,
               trusted_servers: servers,
               on_failure: :drop,
               timeout: 1_000
             )

    on_exit(down.cleanup)
    assert Enum.map(down.tools, &to_string(&1.name)) == ["look"]
    assert [%{server: "other", index: 1}] = down.unavailable
  end

  # What used to be silently resolved by renaming. Two servers claiming one name
  # is a defect in the declaration, and the refusal names the tool, both servers
  # and -- in the log -- the option that fixes it. It is a refusal under
  # `on_failure: :drop` as well: dropping is for what the network did.
  #
  # This is the trade the rule makes, and it is stated in the moduledoc: while
  # one of the two is absent the collision goes unnoticed, and the morning they
  # both answer it refuses. A refusal in one edit beats a rename of a name other
  # things are addressing, which happens on exactly the same morning.
  test "two unprefixed servers offering one tool name refuse the import, naming both" do
    servers = [server("one"), server("two")]

    assert {:error, {:mcp_tool_name_collision, "look", ["one", "two"]}} =
             Imp.MCP.connect(servers, trusted_servers: servers)

    assert {:error, {:mcp_tool_name_collision, "look", ["one", "two"]}} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop)

    # And the fix is one word in the declaration.
    fixed = [Map.put(hd(servers), "tool_prefix", "one_"), List.last(servers)]
    assert {:ok, imported} = Imp.MCP.connect(fixed, trusted_servers: fixed)
    on_exit(imported.cleanup)
    assert Enum.sort(Enum.map(imported.tools, &to_string(&1.name))) == ["look", "one_look"]
  end

  # The names the program has already taken are refused the same way, rather
  # than the server's tool being renamed out from under the caller. One declared
  # server, so there is nothing else this could be a collision with.
  test "a tool named after one the program reserves is refused, not renamed" do
    only = server("only")

    assert {:error, {:mcp_tool_name_collision, "look", ["only"]}} =
             Imp.MCP.connect([only], trusted_servers: [only], reserved_tool_names: ["look"])

    # Unreserved, the same declaration imports under the server's own name.
    assert {:ok, plain} = Imp.MCP.connect([only], trusted_servers: [only])
    assert Enum.map(plain.tools, & &1.name) == [:look]
    assert :ok = plain.cleanup.()

    # And a prefix moves it off the reserved name, because the check is on the
    # name the program will see.
    prefixed = [Map.put(only, "tool_prefix", "only_")]

    assert {:ok, imported} =
             Imp.MCP.connect(prefixed,
               trusted_servers: prefixed,
               reserved_tool_names: ["look"]
             )

    on_exit(imported.cleanup)
    assert Enum.map(imported.tools, &to_string(&1.name)) == ["only_look"]
  end

  # A prefix that is not a string is a declaration this cannot act on, so it is
  # refused before anything is dialed, like an auth shape it does not know.
  test "a tool_prefix that is not a string refuses the import" do
    servers = [Map.put(server("one"), "tool_prefix", 7)]

    assert {:error, {:invalid_tool_prefix, "one", _shape}} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop)
  end

  test "generic import retains source identity under declared prefixes" do
    servers = [
      Map.put(server("one"), "tool_prefix", "one_"),
      Map.put(server("two"), "tool_prefix", "two_")
    ]

    assert {:ok, imported} = Imp.MCP.connect(servers, trusted_servers: servers)
    on_exit(imported.cleanup)
    assert length(imported.tools) == 2
    assert Enum.uniq_by(imported.tools, & &1.name) == imported.tools
    assert Enum.sort(Enum.map(imported.tools, &to_string(&1.name))) == ["one_look", "two_look"]

    for tool <- imported.tools do
      source = tool.metadata.mcp
      assert source.server_name in ["one", "two"]
      assert source.tool_name == "look"
      assert source.schema["name"] == "look"
      assert source.annotations["readOnlyHint"] == true
      assert source == imported.provenance[to_string(tool.name)]
      assert Imp.Tool.call(tool, %{}) == "observed"
      renamed = %{tool | name: "model_friendly_alias"}
      assert renamed.metadata.mcp == source
      assert Imp.Tool.call(renamed, %{}) == "observed"
    end

    assert :ok = imported.cleanup.()
    for tool <- imported.tools, do: assert(match?({:error, _}, Imp.Tool.call(tool, %{})))
  end

  test "HTTP convenience constructor has explicit close and keeps metadata" do
    server = server("fixture")
    client = Imp.MCP.HTTPClient.new(server["url"])
    on_exit(fn -> Imp.MCP.Client.close(client) end)
    [tool] = Imp.MCP.import_tools(client)
    assert tool.metadata.mcp.tool_name == "look"
    assert Imp.Tool.call(tool, %{}) == "observed"
    assert :ok = Imp.MCP.Client.close(client)
    assert {:error, _} = Imp.Tool.call(tool, %{})
  end

  test "structured uncertain write outcome survives the wire without retry" do
    Process.register(self(), :mcp_failure_probe)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        ExMCP.HttpPlug,
        [
          handler: FailureServer,
          server_info: %{name: "failure", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    client = Imp.MCP.HTTPClient.new("http://127.0.0.1:#{port}", result_mode: :structured)
    on_exit(fn -> Imp.MCP.Client.close(client) end)
    [tool] = Imp.MCP.import_tools(client)
    assert {:error, {:mcp_tool_error, failure}} = Imp.Tool.call(tool, %{})

    assert failure["structuredContent"] == %{
             "code" => "indeterminate",
             "operation_id" => "receipt-123"
           }

    assert_receive :publication_attempt
    refute_receive :publication_attempt, 50
  end

  test "broken response stream never replays an unattested write" do
    Process.register(self(), :mcp_failure_probe)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        ExMCP.HttpPlug,
        [
          handler: BrokenServer,
          server_info: %{name: "broken", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    client =
      Imp.MCP.HTTPClient.new("http://127.0.0.1:#{port}",
        timeout: 2000,
        call_meta: fn _ -> %{"progressToken" => "probe"} end
      )

    on_exit(fn -> Imp.MCP.Client.close(client) end)
    [tool] = Imp.MCP.import_tools(client)

    assert {:error,
            {:mcp_tool_call_failed, _, %ExMCP.Error.TransportError{reason: :outcome_unknown}}} =
             Imp.Tool.call(tool, %{})

    assert_receive :broken_attempt
    refute_receive :broken_attempt, 300
  end

  # A descriptor pointing at a port nothing is listening on: the failure a
  # third-party server answering 503, or being down, arrives as.
  defp closed_port_server(name),
    do: %{"name" => name, "type" => "http", "url" => "http://127.0.0.1:#{free_port()}/mcp"}

  defp unlistable_server(name) do
    port = free_port()
    ref = {__MODULE__, :unlistable, port}

    {:ok, _} =
      Plug.Cowboy.http(
        ExMCP.HttpPlug,
        [
          handler: UnlistableServer,
          server_info: %{name: "unlistable", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{"name" => name, "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # A descriptor pointing at a socket that accepts the connection and then
  # answers nothing. This is what a host behind a firewall that drops packets,
  # or a wedged proxy, looks like from here — and it is what "down" usually is;
  # a refused connection is the polite case.
  defp silent_server(name) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, backlog: 128])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    %{"name" => name, "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"}
  end

  # Live ExMCP client processes, so "left out" can be told apart from "left
  # half-open": a client nothing imported from is a socket and a process that
  # nobody will ever close.
  defp client_pids do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          match?({ExMCP.Client, :init, 1}, Keyword.get(dictionary, :"$initial_call"))

        _dead ->
          false
      end
    end)
  end

  test "a server that cannot be reached drops its own tools, not the import" do
    working = server("working")
    servers = [closed_port_server("down"), working]
    before = client_pids()

    assert {:ok, imported} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop, timeout: 5_000)

    on_exit(imported.cleanup)

    # The server after the failing one was still dialed, and its tool is here,
    # under the name its own server gave it: nothing else claims that name, and
    # nothing renames it for the one that did not answer.
    assert Enum.map(imported.tools, & &1.name) == [:look]
    assert Imp.Tool.call(hd(imported.tools), %{}) == "observed"

    assert [%{server: "down", reason: {:mcp_connection_failed, detail}}] = imported.unavailable
    assert is_binary(detail) and detail =~ "econnrefused"
    assert String.length(detail) <= 120

    # One client for the server that answered, none for the one that did not.
    assert length(client_pids() -- before) == 1
    assert :ok = imported.cleanup.()
    assert client_pids() -- before == []
  end

  test "a server that cannot list its tools is dropped and closed with it" do
    servers = [unlistable_server("mute"), server("working")]
    before = client_pids()

    assert {:ok, imported} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop, timeout: 5_000)

    on_exit(imported.cleanup)

    assert Enum.map(imported.tools, & &1.name) == [:look]

    assert [%{server: "mute", index: 0, reason: {:mcp_tools_list_failed, "mute", detail}}] =
             imported.unavailable

    # The message the server sent, not the JSON-RPC envelope it arrived in:
    # this is read in a log line and in an operator's report.
    assert detail == "Tools list failed"
    assert length(client_pids() -- before) == 1
  end

  test "on_failure: :refuse refuses the whole import and leaves no client open" do
    working = server("working")
    servers = [closed_port_server("down"), working]
    before = client_pids()

    assert {:error, reason} =
             Imp.MCP.connect(servers, trusted_servers: servers, timeout: 5_000)

    assert match?({:mcp_connection_failed, _}, reason)
    assert client_pids() -- before == []

    # The same descriptors with the same default, spelled out.
    assert {:error, _} =
             Imp.MCP.connect(servers,
               trusted_servers: servers,
               on_failure: :refuse,
               timeout: 5_000
             )

    assert client_pids() -- before == []
  end

  test "an import that connected everything reports nothing unavailable" do
    servers = [server("one")]

    assert {:ok, imported} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop)

    on_exit(imported.cleanup)
    assert imported.unavailable == []
  end

  test "dropping covers the connection, never the caller's own refusal" do
    working = server("working")
    servers = [closed_port_server("down"), working]

    # An unauthorized descriptor is the caller's answer, not a server's bad
    # hour: it refuses under :drop exactly as it does under :refuse.
    assert {:error, {:mcp_server_not_authorized, "down"}} =
             Imp.MCP.connect(servers, trusted_servers: [working], on_failure: :drop)

    required = [
      Map.put(closed_port_server("keyed"), "auth", %{
        "type" => "bearer_env",
        "variable" => "IMP_TEST_ABSENT_KEY",
        "required" => true
      })
    ]

    System.delete_env("IMP_TEST_ABSENT_KEY")

    assert {:error, {:mcp_auth_unavailable, "keyed", _}} =
             Imp.MCP.connect(required, trusted_servers: required, on_failure: :drop)
  end

  test "a server that accepts the connection and never answers costs its own timeout" do
    working = server("working")
    servers = [silent_server("silent-a"), silent_server("silent-b"), working]
    before = client_pids()

    {micros, result} =
      :timer.tc(fn ->
        Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop, timeout: 2_000)
      end)

    assert {:ok, imported} = result
    on_exit(imported.cleanup)

    # Each dial is bounded on its own, so two silent servers cost two timeouts
    # and the working server behind them is still dialed. Under one budget for
    # the whole list this was {:error, :mcp_import_timeout}, whatever
    # :on_failure said.
    assert Enum.map(imported.tools, & &1.name) == [:look]

    assert [
             %{server: "silent-a", index: 0, reason: {:mcp_connection_failed, :timeout}},
             %{server: "silent-b", index: 1, reason: {:mcp_connection_failed, :timeout}}
           ] = imported.unavailable

    elapsed = div(micros, 1_000)
    assert elapsed < 6_000, "two 2s dials took #{elapsed}ms; they are not bounded one at a time"

    # Neither silent dial left a client behind when it was killed at its deadline.
    assert length(client_pids() -- before) == 1
  end

  test "an absence names which descriptor was left out, not only what it is called" do
    working = server("same")
    servers = [closed_port_server("same"), working]

    assert {:ok, imported} =
             Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop, timeout: 5_000)

    on_exit(imported.cleanup)

    # Two descriptors under one name. A caller told only "same is unavailable"
    # cannot tell which of its own two descriptors that is, and matching by name
    # discards the one that connected.
    assert [%{server: "same", index: 0}] = imported.unavailable
    assert Enum.map(imported.tools, & &1.name) == [:look]
    assert Imp.Tool.call(hd(imported.tools), %{}) == "observed"
  end

  test "a :tool_filter that raises refuses the import, and is never dropped as the server's fault" do
    servers = [server("working")]
    before = client_pids()

    filter = fn _server, _schema -> raise "the caller's filter is broken" end

    # :drop is about servers that did not answer. What the caller's own code
    # did with a catalog that arrived is the caller's answer, and swallowing it
    # would report a healthy server as unavailable.
    assert {:error, {:mcp_tool_import_failed, _detail}} =
             Imp.MCP.connect(servers,
               trusted_servers: servers,
               on_failure: :drop,
               tool_filter: filter,
               timeout: 5_000
             )

    assert client_pids() -- before == []
  end

  test "an unknown on_failure setting is refused by name" do
    assert_raise ArgumentError, ~r/:on_failure must be :refuse or :drop/, fn ->
      Imp.MCP.connect([], on_failure: :ignore)
    end
  end

  test "removed transport knobs refuse with their names rather than silently doing nothing" do
    assert_raise ArgumentError, ~r/transport/, fn ->
      Imp.MCP.HTTPClient.new("http://127.0.0.1:1", transport: :old_mock)
    end
  end
end
