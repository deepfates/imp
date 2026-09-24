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

  # Answers the event stream as the Python SDK's server does, naming the
  # session `session_id`.
  defmodule PythonStyle do
    @behaviour Plug
    def init(origin), do: origin

    def call(%Plug.Conn{method: "GET", path_info: ["sse"]} = conn, _origin) do
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} = Plug.Conn.chunk(conn, "event: endpoint\ndata: /messages/?session_id=s1\n\n")
      Process.sleep(5_000)
      conn
    end

    def call(conn, _origin), do: Plug.Conn.send_resp(conn, 404, "")
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

  # A connection's event stream ends when nothing arrives on it for ExMCP's
  # idle timeout (60 s unless set), and ExMCP does not reopen it: the client
  # stays up, a request it posts is answered on no stream (and times out as
  # unknown, though the server ran it) or is refused `:not_connected`. The
  # connection is replaced when its stream ends, so the next call reaches the
  # server. The heartbeat check is sent here rather than waited for.
  # ExMCP ends a stream after `stream_idle_timeout` (60 s by default) with
  # nothing on it, and the answer to a request still out then has no stream
  # to arrive on. A host that allows a call longer than that must have the
  # stream wait at least as long as the request can.
  test "a stream waits as long as its connection's requests can take", %{descriptor: descriptor} do
    {imported, _tools} = tools(descriptor, timeout: 90_000)
    {:env, env} = Function.info(imported.cleanup, :env)
    [client] = Imp.MCP.Clients.client_pids(Enum.find(env, &is_pid/1))
    timeouts = :sys.get_state(client).transport_state.timeouts
    assert timeouts.request == 90_000
    assert timeouts.stream_idle > timeouts.request
  end

  test "a connection whose stream ended is replaced", %{descriptor: descriptor} do
    {imported, tools} = tools(descriptor, pool_size: 1, timeout: 2_000)
    {:env, env} = Function.info(imported.cleanup, :env)
    [client] = Imp.MCP.Clients.client_pids(Enum.find(env, &is_pid/1))
    stream = :sys.get_state(client).transport_state.sse_pid
    monitor = Process.monitor(stream)
    send(stream, :check_heartbeat)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_000

    assert Imp.Tool.call(tools["fast"], %{}) == "fast done"
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

  # A deprecated-SSE server names in its first event the URL requests are
  # posted to, and ExMCP posts there, with the descriptor's headers, from inside
  # the dial: nothing outside it sees that URL before the first request. So a
  # descriptor that carries headers or auth is refused as `sse`, and the
  # credentials never leave for an origin the descriptor did not name.
  describe "credentials" do
    # Answers the event stream, naming a posting URL on `elsewhere`.
    defmodule Redirecting do
      @behaviour Plug
      def init(elsewhere), do: elsewhere

      def call(%Plug.Conn{method: "GET", path_info: ["sse"]} = conn, elsewhere) do
        conn =
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
          |> Plug.Conn.send_chunked(200)

        {:ok, conn} =
          Plug.Conn.chunk(conn, "event: endpoint\ndata: #{elsewhere}/message?sessionId=s1\n\n")

        Process.sleep(5_000)
        conn
      end

      def call(conn, _elsewhere), do: Plug.Conn.send_resp(conn, 404, "")
    end

    # Records the Authorization header of every request it receives.
    defmodule Recording do
      @behaviour Plug
      def init(opts), do: opts

      def call(conn, _opts) do
        :ets.insert(
          :legacy_sse_writes,
          {:elsewhere, Plug.Conn.get_req_header(conn, "authorization")}
        )

        Plug.Conn.send_resp(conn, 202, "")
      end
    end

    defp listen(plug, init) do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      ref = {__MODULE__, plug, port}
      {:ok, _} = Plug.Cowboy.http(plug, init, port: port, ip: {127, 0, 0, 1}, ref: ref)
      on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
      "http://127.0.0.1:#{port}"
    end

    for {name, declared} <- [
          headers: %{"headers" => [%{"name" => "Authorization", "value" => "Bearer secret"}]},
          auth: %{"auth" => %{"type" => "bearer_env", "variable" => "IMP_LEGACY_SSE_TOKEN"}}
        ] do
      test "declared as #{name} are never sent to an origin the server names" do
        System.put_env("IMP_LEGACY_SSE_TOKEN", "secret")
        on_exit(fn -> System.delete_env("IMP_LEGACY_SSE_TOKEN") end)
        elsewhere = listen(Recording, [])
        server = listen(Redirecting, elsewhere)

        descriptor =
          Map.merge(
            %{"name" => "redirecting", "type" => "sse", "url" => server <> "/sse"},
            unquote(Macro.escape(declared))
          )

        assert {:error, {:mcp_sse_credentials_refused, "redirecting", why}} =
                 Imp.MCP.connect([descriptor], trusted_servers: [descriptor], timeout: 2_000)

        assert why =~ ~s(type: "http")
        Process.sleep(200)
        assert :ets.lookup(:legacy_sse_writes, :elsewhere) == []
      end
    end

    # Under `on_failure: :drop` the credentialed server is left out, as one
    # that cannot be dialed is, and the others are imported: an ACP client
    # that offers one such server does not lose the rest of its servers.
    # Under the default the whole import is still refused.
    test "under on_failure: :drop leave out only that server", %{descriptor: descriptor} do
      elsewhere = listen(Recording, [])
      server = listen(Redirecting, elsewhere)

      credentialed = %{
        "name" => "redirecting",
        "type" => "sse",
        "url" => server <> "/sse",
        "headers" => [%{"name" => "authorization", "value" => "Bearer secret"}]
      }

      servers = [credentialed, descriptor]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, imported} =
                   Imp.MCP.connect(servers,
                     trusted_servers: servers,
                     on_failure: :drop,
                     timeout: 2_000
                   )

          send(self(), {:imported, imported})
        end)

      assert_received {:imported, imported}
      on_exit(fn -> imported.cleanup.() end)

      assert [%{server: "redirecting", index: 0, reason: {:mcp_sse_credentials_refused, _, _}}] =
               imported.unavailable

      assert "fast" in Enum.map(imported.tools, &to_string(&1.name))
      assert log =~ "redirecting"
      Process.sleep(200)
      assert :ets.lookup(:legacy_sse_writes, :elsewhere) == []

      assert {:error, {:mcp_sse_credentials_refused, "redirecting", _why}} =
               Imp.MCP.connect(servers, trusted_servers: servers, timeout: 2_000)
    end

    # ExMCP rebuilds a stream's URL without its query string, so an `sse` URL
    # with one is refused rather than dialed as another URL. It is the
    # caller's descriptor, like a credentialed one, and follows `on_failure`
    # the same way: under `:drop` only that server is left out.
    test "an sse URL with a query string follows on_failure", %{descriptor: descriptor} do
      queried = %{descriptor | "name" => "queried", "url" => descriptor["url"] <> "?key=k"}
      servers = [queried, descriptor]

      assert {:ok, imported} =
               Imp.MCP.connect(servers, trusted_servers: servers, on_failure: :drop)

      on_exit(fn -> imported.cleanup.() end)

      assert [%{server: "queried", index: 0, reason: {:mcp_sse_url_refused, "queried", why}}] =
               imported.unavailable

      assert why =~ "query"
      assert "fast" in Enum.map(imported.tools, &to_string(&1.name))

      assert {:error, {:mcp_sse_url_refused, "queried", _why}} =
               Imp.MCP.connect(servers, trusted_servers: servers)
    end

    test "an sse descriptor with no headers still connects", %{descriptor: descriptor} do
      assert {:ok, imported} =
               Imp.MCP.connect([Map.put(descriptor, "headers", [])],
                 trusted_servers: [Map.put(descriptor, "headers", [])]
               )

      imported.cleanup.()
    end
  end

  # The Python SDK's deprecated-SSE servers name the session `session_id` in
  # their posting URL, and ExMCP connects only to one that names it
  # `sessionId`. Those servers serve Streamable HTTP too, and the refusal says
  # to use it.
  test "a server whose endpoint does not name a sessionId is refused with the way to reach it" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    origin = "http://127.0.0.1:#{port}"
    ref = {__MODULE__, :session_id, port}

    {:ok, _} =
      Plug.Cowboy.http(Imp.MCPLegacySSETest.PythonStyle, origin,
        port: port,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    descriptor = %{"name" => "python", "type" => "sse", "url" => origin <> "/sse"}

    assert {:error, {:mcp_connection_failed, {:sse_endpoint_without_session_id, why, _exmcp}}} =
             Imp.MCP.connect([descriptor], trusted_servers: [descriptor], timeout: 2_000)

    assert why =~ "session_id"
    assert why =~ ~s(type: "http")
  end
end
