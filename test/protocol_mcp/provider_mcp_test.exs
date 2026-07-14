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
            assert request.headers["mcp-session-id"] == "session-live-mcp"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "stream"}}}}

          {"/mcp-stream", "tools/list"} ->
            {200, tools_response(decoded["id"], "lookup_stream")}

          {"/mcp-stream", "tools/call"} ->
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

    [stream_tool] =
      base_url
      |> then(
        &Imp.MCP.StreamableHTTPClient.new(&1 <> "/mcp-stream", session_id: "session-live-mcp")
      )
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
          ~s({"jsonrpc":"2.0","id":#{id},"result":{"tools":[{"name":"echo_stdio","description":"Echo trusted stdio input.","input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}]}})

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
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{
        tools: [
          %{
            name: name,
            description: "Lookup a live gate fact.",
            input_schema: %{
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
