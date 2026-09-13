defmodule Imp.MCPConnectionTest do
  use ExUnit.Case, async: false
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

  defp server(name) do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    ref = {__MODULE__, port}
    {:ok, _pid} = Server.start_link(transport: :http, port: port, ranch_ref: ref, use_sse: false)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{"name" => name, "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp"}
  end

  test "generic import retains source identity while qualifying duplicate names" do
    servers = [server("one"), server("two")]
    assert {:ok, imported} = Imp.MCP.connect(servers, trusted_servers: servers)
    on_exit(imported.cleanup)
    assert length(imported.tools) == 2
    assert Enum.uniq_by(imported.tools, & &1.name) == imported.tools

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

  test "removed transport knobs refuse with their names rather than silently doing nothing" do
    assert_raise ArgumentError, ~r/transport/, fn ->
      Imp.MCP.HTTPClient.new("http://127.0.0.1:1", transport: :old_mock)
    end
  end
end
