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
        for name <- ~w(slow fast),
            do: %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    def handle_call_tool("slow", _arguments, state) do
      Process.sleep(1_500)
      {:ok, %{"content" => [%{"type" => "text", "text" => "slow done"}]}, state}
    end

    def handle_call_tool("fast", _arguments, state),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "fast done"}]}, state}
  end

  # Answers the first connection's handshake and holds every later one, as a
  # server that takes one session at a time does. Tool requests still answer.
  defmodule OneSession do
    @behaviour Plug
    def init(opts), do: ExMCP.HttpPlug.init(opts)

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      handshakes = :persistent_term.get({__MODULE__, :handshakes})

      unless body =~ ~s("tools/) do
        if :counters.get(handshakes, 1) > 0, do: Process.sleep(:infinity)
        :counters.add(handshakes, 1, 1)
      end

      ExMCP.HttpPlug.call(Plug.Conn.assign(conn, :raw_body, body), opts)
    end
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

  # Each extra dial is bounded by `:timeout` on its own, so the import as a
  # whole must allow for `pool_size` of them per server.
  test "extra connections that never answer cost the server connections, not the import" do
    :persistent_term.put({OneSession, :handshakes}, :counters.new(1, []))
    {imported, tools} = tools(server(OneSession), pool_size: 8, timeout: 1_000)

    assert [_one] = Imp.MCP.Clients.client_pids(imported_bridge(imported))
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
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
