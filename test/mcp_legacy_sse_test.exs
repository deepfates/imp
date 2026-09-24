defmodule Imp.MCPLegacySSETest do
  # `"type" => "sse"` is MCP's deprecated HTTP+SSE transport (protocol
  # 2024-11-05): the client GETs an event stream, the server names in an
  # `endpoint` event the URL to POST requests to, and answers arrive on the
  # stream. ExMCP's own server speaks it when `legacy_http_sse: true`.
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
        for name <- ~w(write fast),
            do: %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}

      {:ok, tools, nil, state}
    end

    def handle_call_tool("write", %{"tag" => tag}, state) do
      :ets.insert(:legacy_sse_writes, {tag, :started})
      Process.sleep(800)
      :ets.insert(:legacy_sse_writes, {tag, :finished})
      {:ok, %{"content" => [%{"type" => "text", "text" => "written"}]}, state}
    end

    def handle_call_tool("fast", _arguments, state),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "fast done"}]}, state}
  end

  # Only the deprecated transport: the stream is a GET, and a POST to it is
  # refused, as the SDKs' servers for that protocol do (the Python SDK's
  # answers 405). ExMCP's server would otherwise take Streamable HTTP there too.
  defmodule OnlyLegacy do
    @behaviour Plug
    def init(opts), do: ExMCP.HttpPlug.init(opts)

    def call(%Plug.Conn{method: "POST", path_info: ["sse"]} = conn, _opts),
      do: Plug.Conn.send_resp(conn, 405, "Method Not Allowed")

    def call(conn, opts), do: ExMCP.HttpPlug.call(conn, opts)
  end

  setup do
    :ets.new(:legacy_sse_writes, [:named_table, :public])
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}

    {:ok, _} =
      Plug.Cowboy.http(
        OnlyLegacy,
        [
          handler: Handler,
          server_info: %{name: "legacy", version: "1"},
          allowed_hosts: ["127.0.0.1"],
          allowed_origins: :any,
          legacy_http_sse: true
        ],
        port: port,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    on_exit(fn ->
      try do
        Plug.Cowboy.shutdown(ref)
      catch
        _kind, _reason -> :ok
      end
    end)

    %{descriptor: %{"name" => "legacy", "type" => "sse", "url" => "http://127.0.0.1:#{port}/sse"}}
  end

  defp tools(descriptor, opts) do
    {:ok, imported} = Imp.MCP.connect([descriptor], [trusted_servers: [descriptor]] ++ opts)
    on_exit(fn -> imported.cleanup.() end)
    {imported, Map.new(imported.tools, &{to_string(&1.name), &1})}
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  test "a server is reached at the URL of its event stream", %{descriptor: descriptor} do
    {_imported, tools} = tools(descriptor, [])
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
  end

  test "each pooled connection is a stream of its own", %{descriptor: descriptor} do
    {imported, tools} = tools(descriptor, pool_size: 2)
    {:env, env} = Function.info(imported.cleanup, :env)
    bridge = Enum.find(env, &is_pid/1)
    assert length(Imp.MCP.Clients.client_pids(bridge)) == 2

    slow = Task.async(fn -> Imp.Tool.call(tools["write"], %{"tag" => "pooled"}) end)
    Process.sleep(100)
    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
    assert Task.await(slow, 5_000) == "written"
  end

  # A retired connection is closed after its request, so the server finishes
  # the write the call timed out on.
  test "a retired connection's request still finishes on the server", %{descriptor: descriptor} do
    {_imported, tools} = tools(descriptor, pool_size: 1, timeout: 300)

    assert {:error, %CallFailure{outcome: :unknown}} =
             Imp.Tool.call(tools["write"], %{"tag" => "retired"})

    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"

    assert eventually(fn ->
             :ets.lookup(:legacy_sse_writes, "retired") == [{"retired", :finished}]
           end)
  end

  # The session is the event stream: a server ends the requests in flight on a
  # session when its stream closes (the Python SDK's does). A retired
  # connection's stream closes only after its request is done, and then it
  # does close.
  test "a retired connection's stream closes only after its request is done",
       %{descriptor: descriptor} do
    {imported, tools} = tools(descriptor, pool_size: 1, timeout: 300)
    {:env, env} = Function.info(imported.cleanup, :env)
    [client] = Imp.MCP.Clients.client_pids(Enum.find(env, &is_pid/1))
    stream = :sys.get_state(client).transport_state.sse_pid
    monitor = Process.monitor(stream)

    assert {:error, %CallFailure{outcome: :unknown}} =
             Imp.Tool.call(tools["write"], %{"tag" => "stream"})

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
    assert :ets.lookup(:legacy_sse_writes, "stream") == [{"stream", :finished}]
  end
end
