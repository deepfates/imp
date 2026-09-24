defmodule Imp.MCPHTTPPublicServerTest.PublicServer do
  @moduledoc false
  # Answers MCP the way public servers do rather than the way ExMCP's own server
  # does: at the site root, refusing browser-style Origin headers, and not
  # knowing ExMCP's `server/discover` probe. Each refusal is switched on per
  # test so a test fails for one reason.

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    %{
      mount: Keyword.fetch!(opts, :mount),
      refuse_origin: Keyword.get(opts, :refuse_origin, false),
      probe_status: Keyword.get(opts, :probe_status),
      notify: Keyword.fetch!(opts, :notify),
      mcp:
        ExMCP.HttpPlug.init(
          handler: Imp.ACP.DemoMCPServer,
          server_info: %{name: "imp-public-server-fixture", version: "0.1.0"},
          allowed_hosts: ["localhost", "127.0.0.1", "::1"],
          allowed_origins: :any
        )
    }
  end

  @impl true
  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    method = decode_method(body)
    send(opts.notify, {:request, conn.request_path, method, get_req_header(conn, "origin")})

    cond do
      conn.request_path != opts.mount ->
        send_resp(conn, 404, "not found")

      opts.refuse_origin and get_req_header(conn, "origin") != [] ->
        send_resp(conn, 403, "Origin not permitted")

      opts.probe_status && method == "server/discover" ->
        send_resp(conn, opts.probe_status, "unknown method")

      true ->
        # ExMCP's plug reads a body another plug already read from here.
        conn
        |> assign(:raw_body, body)
        |> ExMCP.HttpPlug.call(opts.mcp)
    end
  end

  defp decode_method(body) do
    case Jason.decode(body) do
      {:ok, %{"method" => method}} -> method
      _other -> nil
    end
  end
end

defmodule Imp.MCPHTTPPublicServerTest do
  use ExUnit.Case, async: false

  alias Imp.MCPHTTPPublicServerTest.PublicServer

  @moduletag capture_log: true

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  test "a server that answers at its root is reached at its root" do
    url = public_server(mount: "/") <> "/"

    assert {:ok, imported} = connect(url)
    assert Enum.map(imported.tools, &to_string(&1.name)) == ["external_workspace_name"]
    imported.cleanup.()

    refute_received {:request, "/mcp/v1", _method, _origin}
  end

  test "no Origin header is sent, so a server that refuses browser origins answers" do
    url = public_server(mount: "/mcp", refuse_origin: true) <> "/mcp"

    assert {:ok, imported} = connect(url)
    imported.cleanup.()

    assert_received {:request, "/mcp", _method, []}
    refute_received {:request, _path, _method, [_origin]}
  end

  test "a server that answers the era probe with 404 is reached through initialize" do
    url = public_server(mount: "/mcp", probe_status: 404) <> "/mcp"

    assert {:ok, imported} = connect(url)
    assert Enum.map(imported.tools, &to_string(&1.name)) == ["external_workspace_name"]
    imported.cleanup.()

    assert_received {:request, "/mcp", "server/discover", _origin}
    assert_received {:request, "/mcp", "initialize", _origin}
  end

  test "a 401 on the era probe is not retried as a protocol problem" do
    url = public_server(mount: "/mcp", probe_status: 401) <> "/mcp"

    assert {:error, _reason} = connect(url)

    assert_received {:request, "/mcp", "server/discover", _origin}
    refute_received {:request, "/mcp", "initialize", _origin}
  end

  defp connect(url) do
    server = %{"name" => "public", "type" => "http", "url" => url}
    Imp.MCP.connect([server], trusted_servers: [server], timeout: 10_000)
  end

  defp public_server(opts) do
    port = free_port()
    ref = {__MODULE__, port}

    {:ok, _server} =
      Plug.Cowboy.http(PublicServer, Keyword.put(opts, :notify, self()),
        port: port,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
