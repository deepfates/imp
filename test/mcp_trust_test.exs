defmodule Imp.MCPTrustTest do
  # ExMCP's request check reads one VM-wide trusted-origin list. An authorized
  # remote server's exact origin is in it while a connection to it is open,
  # and only then; what the host configured itself is never touched.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  setup do
    previous = Application.get_env(:ex_mcp, :security)

    Application.put_env(:ex_mcp, :security,
      trusted_origins: ["https://configured.example:443"],
      trusted_hosts: [],
      consent_handler: ExMCP.ConsentHandler.Deny
    )

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ex_mcp, :security),
        else: Application.put_env(:ex_mcp, :security, previous)
    end)
  end

  test "an authorized server's origin is trusted while its connection is open, and only then" do
    %{url: url, origin: origin} = credentialed_server("Bearer trust-test-token")

    server = %{
      "name" => "credentialed",
      "type" => "http",
      "url" => url,
      "headers" => [%{"name" => "Authorization", "value" => "Bearer trust-test-token"}]
    }

    assert {:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server])
    assert_received {:mcp_http_auth, :accepted}

    assert origin in trusted_origins()
    assert "https://configured.example:443" in trusted_origins()

    assert :ok = imported.cleanup.()

    assert eventually(fn -> origin not in trusted_origins() end),
           "#{origin} stayed trusted after its only connection closed"

    assert trusted_origins() == ["https://configured.example:443"]
  end

  test "an origin two connections share stays trusted until the second one closes" do
    %{url: url, origin: origin} = credentialed_server("Bearer trust-test-token")

    server = %{
      "name" => "credentialed",
      "type" => "http",
      "url" => url,
      "headers" => [%{"name" => "Authorization", "value" => "Bearer trust-test-token"}]
    }

    assert {:ok, first} = Imp.MCP.connect([server], trusted_servers: [server])
    assert {:ok, second} = Imp.MCP.connect([server], trusted_servers: [server])

    assert :ok = first.cleanup.()
    Process.sleep(100)
    assert origin in trusted_origins()

    assert :ok = second.cleanup.()
    assert eventually(fn -> origin not in trusted_origins() end)
  end

  test "a crash of the process that added an origin does not leave it trusted" do
    origin = "https://crash.example:443"
    holder = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(holder, :kill) end)

    assert :ok = Imp.MCP.Trust.hold(origin, holder)
    assert origin in trusted_origins()

    trust = Process.whereis(Imp.MCP.Trust)
    Process.exit(trust, :kill)

    assert eventually(fn ->
             restarted = Process.whereis(Imp.MCP.Trust)
             is_pid(restarted) and restarted != trust
           end)

    assert eventually(fn -> origin not in trusted_origins() end),
           "#{origin} stayed trusted after the process that added it crashed"

    assert trusted_origins() == ["https://configured.example:443"]
  end

  defp trusted_origins do
    :ex_mcp |> Application.get_env(:security) |> Keyword.get(:trusted_origins)
  end

  defp credentialed_server(authorization) do
    port = free_port()
    ref = {__MODULE__, port}

    {:ok, _server} =
      Plug.Cowboy.http(
        Imp.ACP.DemoMCPHTTPPlug,
        [expected_authorization: authorization, notify: self()],
        port: port,
        ip: {127, 0, 0, 1},
        ref: ref
      )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{url: "http://127.0.0.1:#{port}", origin: "http://127.0.0.1:#{port}"}
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
