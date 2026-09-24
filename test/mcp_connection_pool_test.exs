defmodule Imp.MCPConnectionPoolTest do
  # One ExMCP client sends one HTTP request at a time: it makes the POST from
  # inside its own process, so a quick call made while a slow one is out waits
  # for it. A host whose conversations call one server at once asks for
  # `pool_size:` connections per server, and a call then waits only when every
  # one of them is busy.
  use ExUnit.Case, async: false

  alias Imp.MCP.CallFailure

  @moduletag capture_log: true

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  defmodule Handler do
    use ExMCP.Server.Handler
    def init(_), do: {:ok, %{}}

    def handle_list_tools(_cursor, state) do
      tools =
        for name <- ~w(slow fast write),
            do: %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    def handle_call_tool("slow", _arguments, state) do
      Process.sleep(1_500)
      {:ok, %{"content" => [%{"type" => "text", "text" => "slow done"}]}, state}
    end

    # A write that takes a while and says when it is done.
    def handle_call_tool("write", %{"tag" => tag}, state) do
      :ets.insert(:pool_test_writes, {tag, :started})
      Process.sleep(800)
      :ets.insert(:pool_test_writes, {tag, :finished})
      {:ok, %{"content" => [%{"type" => "text", "text" => "written"}]}, state}
    end

    def handle_call_tool("fast", _arguments, state),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "fast done"}]}, state}
  end

  # Answers the first `answered` connections' handshakes (one by default), or
  # those whose place in arrival order is in the list `answered`, and holds
  # every other one, as a server that takes one session at a time does,
  # or refuses it with a 503 when `later` is `:refuse`. Tool requests still
  # answer.
  defmodule OneSession do
    @behaviour Plug
    def init(opts), do: ExMCP.HttpPlug.init(opts)

    def setup(answered \\ 1, later \\ :hold) do
      :persistent_term.put({__MODULE__, :handshakes}, :counters.new(1, []))
      :persistent_term.put({__MODULE__, :answered}, answered)
      :persistent_term.put({__MODULE__, :later}, later)
    end

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      handshakes = :persistent_term.get({__MODULE__, :handshakes})

      if body =~ ~s("tools/) do
        ExMCP.HttpPlug.call(Plug.Conn.assign(conn, :raw_body, body), opts)
      else
        seen = :counters.get(handshakes, 1)
        :counters.add(handshakes, 1, 1)

        cond do
          answered?(seen, :persistent_term.get({__MODULE__, :answered})) ->
            ExMCP.HttpPlug.call(Plug.Conn.assign(conn, :raw_body, body), opts)

          :persistent_term.get({__MODULE__, :later}) == :refuse ->
            Plug.Conn.send_resp(conn, 503, "one session at a time")

          true ->
            Process.sleep(:infinity)
        end
      end
    end

    defp answered?(seen, answered) when is_list(answered), do: seen in answered
    defp answered?(seen, answered), do: seen < answered
  end

  defp server(plug \\ ExMCP.HttpPlug) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        plug,
        [
          handler: Handler,
          server_info: %{name: "pool", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any
        ],
        port: port,
        ref: ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ref)
      catch
        _kind, _reason -> :ok
      end
    end)

    %{"name" => "pool", "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"}
  end

  defp tools(descriptor, opts) do
    {:ok, imported} = Imp.MCP.connect([descriptor], [trusted_servers: [descriptor]] ++ opts)
    on_exit(fn -> imported.cleanup.() end)
    {imported, Map.new(imported.tools, &{to_string(&1.name), &1})}
  end

  defp ms(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  test "with a pool, a quick call does not wait behind a slow one to the same server" do
    {_imported, tools} = tools(server(), pool_size: 2)

    slow = Task.async(fn -> Imp.Tool.call(tools["slow"], %{}) end)
    Process.sleep(200)

    {elapsed, result} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
    assert result == "fast done"
    assert elapsed < 500, "the quick call waited #{elapsed} ms"
    assert Task.await(slow, 5_000) == "slow done"
  end

  test "with one connection a quick call waits behind a slow one, which is why the pool exists" do
    {_imported, tools} = tools(server(), pool_size: 1)

    slow = Task.async(fn -> Imp.Tool.call(tools["slow"], %{}) end)
    Process.sleep(200)

    {elapsed, "fast done"} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
    assert elapsed >= 1_000
    assert Task.await(slow, 5_000) == "slow done"
  end

  test "a call that finds every connection busy until its timeout was not sent" do
    {imported, tools} = tools(server(), pool_size: 1, timeout: 300)

    # Hold the server's one connection, the way a call in progress holds it.
    holder =
      Task.async(fn ->
        {:ok, client} = Imp.MCP.Clients.checkout(imported_bridge(imported), 0, 1_000)

        receive do
          :release -> Imp.MCP.Clients.checkin(imported_bridge(imported), client)
        end
      end)

    Process.sleep(100)

    {elapsed, result} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
    assert {:error, %CallFailure{outcome: :not_sent, tool: "fast"}} = result
    assert elapsed >= 300

    send(holder.pid, :release)
    Task.await(holder)

    # Given back, it is lent again.
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
  end

  test "a borrower that dies gives its connection back" do
    {imported, tools} = tools(server(), pool_size: 1, timeout: 1_000)

    holder =
      spawn(fn ->
        {:ok, _client} = Imp.MCP.Clients.checkout(imported_bridge(imported), 0, 1_000)
        Process.sleep(:infinity)
      end)

    Process.sleep(100)
    Process.exit(holder, :kill)
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
  end

  test "each pooled connection is closed with the import" do
    {imported, tools} = tools(server(), pool_size: 3)
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"

    bridge_clients = Imp.MCP.Clients.client_pids(imported_bridge(imported))
    assert length(bridge_clients) == 3

    imported.cleanup.()
    Process.sleep(100)
    refute Enum.any?(bridge_clients, &Process.alive?/1)
  end

  # Each extra dial is bounded by `:timeout` on its own, and the import's time
  # limit allows a round of them per server.
  test "extra connections that never answer cost the server connections, not the import" do
    OneSession.setup()
    {imported, tools} = tools(server(OneSession), pool_size: 8, timeout: 1_000)

    assert [_one] = Imp.MCP.Clients.client_pids(imported_bridge(imported))
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
  end

  # The extra connections to a server are dialed at once, so extras that never
  # answer cost the import one `:timeout`, not one each.
  test "a server's extra connections are dialed at once" do
    OneSession.setup()

    {elapsed, {imported, _tools}} =
      ms(fn -> tools(server(OneSession), pool_size: 4, timeout: 1_000) end)

    assert [_one] = Imp.MCP.Clients.client_pids(imported_bridge(imported))
    assert elapsed < 2_000, "three held extra dials took #{elapsed} ms"
  end

  # The import's time limit allows each server its first dial, the one
  # fallback dial and one round of extra dials. An import given up while extras
  # are still dialing closes every connection it made, the ones that answered
  # and the ones still in their handshake.
  test "an import given up while extra connections dial closes every one" do
    # Of seven extras the first three to arrive are held and the rest answer,
    # so answers wait to be taken while the import still awaits held ones.
    OneSession.setup([0, 4, 5, 6, 7])
    descriptor = server(OneSession)
    origin = String.replace(descriptor["url"], "/mcp", "")
    before = exmcp_clients()

    # Limit: 3 * 1_000 + 5_000. The extras start at about 7_300 ms, the held
    # ones would hold until 8_300 ms, and the import is given up at 8_000.
    authorize = fn _descriptor ->
      Process.sleep(7_300)
      :ok
    end

    assert {:error, :mcp_import_timeout} =
             Imp.MCP.connect([descriptor], authorize: authorize, pool_size: 8, timeout: 1_000)

    assert eventually(fn -> exmcp_clients() -- before == [] end),
           "#{length(exmcp_clients() -- before)} clients outlived the abandoned import"

    assert eventually(fn -> origin not in trusted_origins() end)
  end

  # A call that timed out leaves its request with ExMCP, which is still
  # waiting on it. That connection is closed and a new one dialed, so the next
  # call does not wait behind the old request.
  test "after a call times out the next call does not wait behind it" do
    {_imported, tools} = tools(server(), pool_size: 1, timeout: 400)

    assert {:error, %CallFailure{outcome: :unknown}} = Imp.Tool.call(tools["slow"], %{})

    {elapsed, result} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
    assert result == "fast done"
    assert elapsed < 300, "the next call waited #{elapsed} ms"
  end

  test "after a borrower dies mid-call the next call does not wait behind its request" do
    {_imported, tools} = tools(server(), pool_size: 1, timeout: 5_000)

    {:ok, borrower} = Task.start(fn -> Imp.Tool.call(tools["slow"], %{}) end)
    Process.sleep(200)
    Process.exit(borrower, :kill)

    {elapsed, result} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
    assert result == "fast done"
    assert elapsed < 500, "the next call waited #{elapsed} ms"
  end

  # Retiring a connection takes it out of the pool; it does not cut off the
  # request still out on it. Closing its socket mid-request ends the server's
  # handler with it, and a write that would have finished is left half done.
  describe "a retired connection's request" do
    setup do
      :ets.new(:pool_test_writes, [:named_table, :public])
      :ok
    end

    test "still finishes on the server after its call timed out" do
      {_imported, tools} = tools(server(), pool_size: 1, timeout: 300)

      assert {:error, %CallFailure{outcome: :unknown}} =
               Imp.Tool.call(tools["write"], %{"tag" => "timed out"})

      assert Imp.Tool.call(tools["fast"], %{}) == "fast done"

      assert eventually(fn ->
               :ets.lookup(:pool_test_writes, "timed out") == [{"timed out", :finished}]
             end)
    end

    test "still finishes on the server after its borrower died" do
      {_imported, tools} = tools(server(), pool_size: 1, timeout: 5_000)

      {:ok, borrower} =
        Task.start(fn -> Imp.Tool.call(tools["write"], %{"tag" => "orphaned"}) end)

      assert eventually(fn -> :ets.lookup(:pool_test_writes, "orphaned") != [] end)
      Process.exit(borrower, :kill)

      assert Imp.Tool.call(tools["fast"], %{}) == "fast done"

      assert eventually(fn ->
               :ets.lookup(:pool_test_writes, "orphaned") == [{"orphaned", :finished}]
             end)
    end
  end

  # A replacement that cannot be dialed leaves the server with one connection
  # fewer; with none left, its calls are not sent and say so.
  test "a replacement that cannot be dialed shrinks the pool" do
    OneSession.setup(1, :refuse)
    {imported, tools} = tools(server(OneSession), pool_size: 1, timeout: 400)

    assert {:error, %CallFailure{outcome: :unknown}} = Imp.Tool.call(tools["slow"], %{})

    assert {:error, %CallFailure{outcome: :not_sent, reason: :not_connected}} =
             Imp.Tool.call(tools["fast"], %{})

    assert Imp.MCP.Clients.client_pids(imported_bridge(imported)) == []
  end

  defp exmcp_clients do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          match?({ExMCP.Client, _, _}, dictionary[:"$initial_call"])

        nil ->
          false
      end
    end)
  end

  # Each pooled connection holds its server's origin in `Imp.MCP.Trust` for as
  # long as it lives, so the origin stays trusted while any of them is open.
  test "the origin stays trusted while any pooled connection to it is open" do
    descriptor = server()
    origin = String.replace(descriptor["url"], "/mcp", "")
    {imported, tools} = tools(descriptor, pool_size: 2)
    [first, second] = Imp.MCP.Clients.client_pids(imported_bridge(imported))

    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    Process.sleep(100)

    assert origin in trusted_origins()
    assert Process.alive?(second)
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
  end

  # A stdio server takes calls to one connection at once: ExMCP writes each
  # request to the pipe and matches the answers by id. Each further connection
  # would be another server process with state of its own, so a stdio server
  # has one, whatever `pool_size` says, and its calls go straight to it.
  describe "a stdio server" do
    @stdio """
    import json, os, sys, threading, time
    with open(os.environ["POOL_PID_FILE"], "a") as f:
        f.write(str(os.getpid()) + "\\n")
    lock = threading.Lock()
    def out(r):
        with lock:
            sys.stdout.write(json.dumps(r) + "\\n")
            sys.stdout.flush()
    def slow(i):
        time.sleep(1.5)
        out({"jsonrpc": "2.0", "id": i, "result": {"content": [{"type": "text", "text": "slow done"}]}})
    for line in sys.stdin:
        q = json.loads(line)
        m = q.get("method")
        if m == "initialize":
            out({"jsonrpc": "2.0", "id": q["id"], "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "s", "version": "1"}}})
        elif m == "tools/list":
            out({"jsonrpc": "2.0", "id": q["id"], "result": {"tools": [{"name": n, "description": n, "inputSchema": {"type": "object"}} for n in ["slow", "fast"]]}})
        elif m == "tools/call":
            if q["params"]["name"] == "slow":
                threading.Thread(target=slow, args=(q["id"],)).start()
            else:
                out({"jsonrpc": "2.0", "id": q["id"], "result": {"content": [{"type": "text", "text": "fast done"}]}})
        elif q.get("id") is not None:
            out({"jsonrpc": "2.0", "id": q["id"], "error": {"code": -32601, "message": "not found"}})
    """

    setup do
      dir = Path.join(System.tmp_dir!(), "imp-pool-stdio-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      script = Path.join(dir, "server.py")
      File.write!(script, @stdio)
      pid_file = Path.join(dir, "pids")
      python = System.find_executable("python3") || raise "python3 required for this test"

      descriptor = %{
        "name" => "stdio",
        "type" => "stdio",
        "command" => python,
        "args" => [script],
        "env" => [%{"name" => "POOL_PID_FILE", "value" => pid_file}]
      }

      %{descriptor: descriptor, pid_file: pid_file}
    end

    test "answers a quick call during a slow one on its one connection", %{descriptor: d} do
      {_imported, tools} = tools(d, timeout: 10_000)

      slow = Task.async(fn -> Imp.Tool.call(tools["slow"], %{}) end)
      Process.sleep(200)

      {elapsed, result} = ms(fn -> Imp.Tool.call(tools["fast"], %{}) end)
      assert result == "fast done"
      assert elapsed < 500, "the quick call waited #{elapsed} ms"
      assert Task.await(slow, 5_000) == "slow done"
    end

    test "is one server process whatever pool_size says", %{descriptor: d, pid_file: pid_file} do
      {imported, _tools} = tools(d, pool_size: 3, timeout: 10_000)

      assert [_one] = Imp.MCP.Clients.client_pids(imported_bridge(imported))
      assert [_one] = pid_file |> File.read!() |> String.split("\n", trim: true)
    end

    # The import's own time limit is a backstop for its helper wedging; the
    # caller's `:authorize` runs in that helper. A connection already made when
    # the helper is abandoned is closed with it, and so is its server process.
    test "an import abandoned after connecting it leaves no server running",
         %{descriptor: d, pid_file: pid_file} do
      wedged = %{d | "name" => "wedged"}
      parent = self()

      authorize = fn
        %{"name" => "wedged"} ->
          send(parent, :wedged)
          Process.sleep(:infinity)

        _descriptor ->
          :ok
      end

      task =
        Task.async(fn -> Imp.MCP.connect([d, wedged], authorize: authorize, timeout: 500) end)

      assert_receive :wedged, 10_000
      [os_pid] = pid_file |> File.read!() |> String.split("\n", trim: true)
      assert {:error, :mcp_import_timeout} = Task.await(task, 30_000)

      assert eventually(fn -> not os_alive?(os_pid) end),
             "the stdio server #{os_pid} outlived the abandoned import"
    end
  end

  defp os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  defp trusted_origins do
    case Application.get_env(:ex_mcp, :security) do
      security when is_list(security) -> Keyword.get(security, :trusted_origins, [])
      security when is_map(security) -> Map.get(security, :trusted_origins, [])
      _unset -> []
    end
  end

  # The caller can die while its import is still connecting: a turn cancelled,
  # a task killed at its own deadline. The connections already made must close
  # with it, and with them their hold on the server's origin.
  describe "a caller that dies while its import connects" do
    test "leaves no connection open when the rest connect", do: caller_dies(:ok)
    test "leaves no connection open when the rest are refused", do: caller_dies(false)
  end

  defp caller_dies(second_answer) do
    first = server()
    second = %{server() | "name" => "second"}

    caller =
      spawn(fn ->
        caller = self()

        authorize = fn
          %{"name" => "second"} ->
            Process.exit(caller, :kill)
            second_answer

          _descriptor ->
            :ok
        end

        Imp.MCP.connect([first, second], authorize: authorize, pool_size: 2)
      end)

    monitor = Process.monitor(caller)
    assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 5_000
    origin = String.replace(first["url"], "/mcp", "")

    assert eventually(fn -> origin not in trusted_origins() end),
           "a connection to #{origin} outlived the caller that was importing it"
  end

  test "pool_size must be a positive integer" do
    assert_raise ArgumentError, ~r/pool_size/, fn ->
      Imp.MCP.connect([server()], trusted_servers: [server()], pool_size: 0)
    end
  end

  # The bridge an import's cleanup stops, read from the cleanup's closure.
  defp imported_bridge(imported) do
    {:env, env} = Function.info(imported.cleanup, :env)
    Enum.find(env, &is_pid/1)
  end
end
