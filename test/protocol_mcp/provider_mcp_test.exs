defmodule ProtocolMCPProviderTest do
  use ExUnit.Case

  @moduletag :protocol_mcp

  test "protocol MCP gate exercises JSON-RPC HTTP and Streamable HTTP clients" do
    ref =
      Imp.Test.TelemetryHelpers.attach([
        [:imp, :mcp, :http, :start],
        [:imp, :mcp, :streamable_http, :start]
      ])

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.headers["mcp-protocol-version"] == "2025-03-26"

        decoded = Jason.decode!(request.body)
        method = decoded["method"]

        case {request.path, method} do
          {"/mcp-http", "initialize"} ->
            # MCP spec, Lifecycle: initialize MUST carry full params.
            assert get_in(decoded, ["params", "protocolVersion"]) == "2025-03-26"
            assert get_in(decoded, ["params", "clientInfo", "name"]) == "imp"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "http"}}}}

          {"/mcp-http", "notifications/initialized"} ->
            {200, %{jsonrpc: "2.0", result: %{}}}

          {"/mcp-http", "tools/list"} ->
            {200, tools_response(decoded["id"], "lookup_http")}

          {"/mcp-http", "tools/call"} ->
            assert get_in(decoded, ["params", "name"]) == "lookup_http"
            assert get_in(decoded, ["params", "arguments", "key"]) == "capital"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: "Paris"}}

          {"/mcp-stream", "initialize"} ->
            assert request.headers["accept"] =~ "text/event-stream"
            # MCP spec, Lifecycle: initialize MUST carry full params.
            assert get_in(decoded, ["params", "protocolVersion"]) == "2025-03-26"
            assert get_in(decoded, ["params", "clientInfo", "name"]) == "imp"
            # No session exists before the server assigns one at initialize.
            refute Map.has_key?(request.headers, "mcp-session-id")

            # MCP spec, Streamable HTTP session management: the server assigns
            # the session id via the Mcp-Session-Id response header.
            {200, [{"mcp-session-id", "session-live-mcp"}],
             %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "stream"}}}}

          {"/mcp-stream", "notifications/initialized"} ->
            # MCP spec, Lifecycle + Streamable HTTP: the client MUST send
            # notifications/initialized; the server answers 202 with no body.
            assert request.headers["mcp-session-id"] == "session-live-mcp"
            {202, ""}

          {"/mcp-stream", "tools/list"} ->
            assert request.headers["mcp-session-id"] == "session-live-mcp"
            {200, tools_response(decoded["id"], "lookup_stream")}

          {"/mcp-stream", "tools/call"} ->
            assert request.headers["mcp-session-id"] == "session-live-mcp"
            assert get_in(decoded, ["params", "name"]) == "lookup_stream"
            assert get_in(decoded, ["params", "arguments", "key"]) == "runtime"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: "BEAM"}}
        end
      end)

    [http_tool] =
      base_url
      |> then(&Imp.MCP.HTTPClient.new(&1 <> "/mcp-http"))
      |> Imp.MCP.import_tools()

    assert http_tool.name == :lookup_http
    assert Imp.Tool.call(http_tool, %{"key" => "capital"}) == "Paris"

    # The client starts without a session id: the server assigns one on the
    # initialize response and the client must echo it on later requests.
    [stream_tool] =
      base_url
      |> then(&Imp.MCP.StreamableHTTPClient.new(&1 <> "/mcp-stream"))
      |> Imp.MCP.import_tools()

    assert stream_tool.name == :lookup_stream
    assert Imp.Tool.call(stream_tool, %{"key" => "runtime"}) == "BEAM"

    assert_received {^ref, [:imp, :mcp, :http, :start], _, %{method: "initialize"}}

    assert_received {^ref, [:imp, :mcp, :streamable_http, :start], _, %{method: "initialize"}}
  end

  test "protocol MCP gate exercises trusted stdio client" do
    script =
      Path.join(System.tmp_dir!(), "imp-live-mcp-#{System.unique_integer([:positive])}.exs")

    File.write!(script, ~S"""
    Enum.each(IO.stream(:stdio, :line), fn request ->
      method = Regex.run(~r/"method":"([^"]+)"/, request, capture: :all_but_first)
      id = Regex.run(~r/"id":(\d+)/, request, capture: :all_but_first)

      response = case {method, id} do
        {["initialize"], [id]} ->
          ~s({"jsonrpc":"2.0","id":#{id},"result":{"serverInfo":{"name":"stdio"}}})

        {["tools/list"], [id]} ->
          # MCP spec, Tool definition: camelCase "inputSchema".
          ~s({"jsonrpc":"2.0","id":#{id},"result":{"tools":[{"name":"echo_stdio","description":"Echo trusted stdio input.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}})

        {["tools/call"], [id]} ->
          [text] = Regex.run(~r/"text":"([^"]*)"/, request, capture: :all_but_first)
          ~s({"jsonrpc":"2.0","id":#{id},"result":"#{text}"})

        _ ->
          nil
      end

      if response, do: IO.puts(response)
    end)
    """)

    on_exit(fn -> File.rm(script) end)

    [tool] =
      System.find_executable("elixir")
      |> Imp.MCP.StdioClient.new(args: [script], timeout: 15_000)
      |> Imp.MCP.import_tools()

    assert tool.name == :echo_stdio
    assert Imp.Tool.call(tool, %{"text" => "trusted"}) == "trusted"
  end

  defp tools_response(id, name) do
    # MCP spec, Tool definition: camelCase "inputSchema".
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        tools: [
          %{
            name: name,
            description: "Lookup a live gate fact.",
            inputSchema: %{
              type: "object",
              properties: %{key: %{type: "string"}},
              required: ["key"]
            }
          }
        ]
      }
    }
  end
end
