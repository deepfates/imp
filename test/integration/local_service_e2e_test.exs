defmodule LocalServiceE2ETest do
  use ExUnit.Case

  @moduletag :integration

  test "HTTP retriever performs a real local HTTP request and maps documents" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/retrieve"
        assert %{"query" => "beam", "k" => 2} = Jason.decode!(request.body)

        {200,
         %{
           documents: [
             %{text: "BEAM document", score: 0.9, source: "local"}
           ]
         }}
      end)

    retriever = DSEx.Retrievers.HTTP.new(base_url <> "/retrieve")

    assert {:ok, [%{text: "BEAM document", score: 0.9, metadata: %{"source" => "local"}}]} =
             DSEx.Retrieve.retrieve(retriever, "beam", k: 2)
  end

  test "HTTP MCP client discovers and calls a local JSON-RPC tool server" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)

        case decoded["method"] do
          "initialize" ->
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "local"}}}}

          "notifications/initialized" ->
            {200, %{jsonrpc: "2.0", result: %{}}}

          "tools/list" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 tools: [
                   %{
                     name: "lookup",
                     description: "Lookup a local fact.",
                     input_schema: %{
                       type: "object",
                       properties: %{key: %{type: "string"}},
                       required: ["key"]
                     }
                   }
                 ]
               }
             }}

          "tools/call" ->
            assert get_in(decoded, ["params", "name"]) == "lookup"
            assert get_in(decoded, ["params", "arguments", "key"]) == "capital"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: "Paris"}}
        end
      end)

    [tool] = base_url |> DSEx.MCP.HTTPClient.new() |> DSEx.MCP.import_tools()

    assert tool.name == :lookup
    assert DSEx.Tool.call(tool, %{"key" => "capital"}) == "Paris"
  end

  test "stdio MCP client discovers and calls a trusted local executable" do
    script = Path.join(System.tmp_dir!(), "dsex-mcp-#{System.unique_integer([:positive])}.exs")

    File.write!(script, """
    Enum.each(IO.stream(:stdio, :line), fn line ->
      request = Jason.decode!(line)
      response =
        case request["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}}
          "tools/list" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => [%{"name" => "echo", "description" => "Echo input", "input_schema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}}]}}
          "tools/call" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => request["params"]["arguments"]["text"]}
          _ ->
            nil
        end

      if response, do: IO.puts(Jason.encode!(response))
    end)
    """)

    on_exit(fn -> File.rm(script) end)

    [tool] =
      System.find_executable("mix")
      |> DSEx.MCP.StdioClient.new(args: ["run", script], timeout: 15_000)
      |> DSEx.MCP.import_tools()

    assert tool.name == :echo
    assert DSEx.Tool.call(tool, %{"text" => "hello"}) == "hello"
  end

  test "tool programs accept provider JSON string arguments end to end" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)

        case decoded["method"] do
          "initialize" ->
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: %{serverInfo: %{name: "local"}}}}

          "notifications/initialized" ->
            {200, %{jsonrpc: "2.0", result: %{}}}

          "tools/list" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 tools: [
                   %{
                     name: "lookup",
                     description: "Lookup a local fact.",
                     input_schema: %{
                       type: "object",
                       properties: %{key: %{type: "string"}},
                       required: ["key"]
                     }
                   }
                 ]
               }
             }}

          "tools/call" ->
            assert get_in(decoded, ["params", "name"]) == "lookup"
            assert get_in(decoded, ["params", "arguments", "key"]) == "capital"
            {200, %{jsonrpc: "2.0", id: decoded["id"], result: "Paris"}}
        end
      end)

    [tool] = base_url |> DSEx.MCP.HTTPClient.new() |> DSEx.MCP.import_tools()

    assert_react_json_tool_arguments(tool)
    assert_rlm_json_tool_arguments(tool)
    assert_code_act_json_tool_arguments(tool)
  end

  defp assert_react_json_tool_arguments(tool) do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: ~s({"key":"capital"})}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    lm = action_lm(actions)
    program = DSEx.react("question -> answer", [tool], lm: lm, max_iters: 3)

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(program, %{question: "capital?"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
  end

  defp assert_rlm_json_tool_arguments(tool) do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{action: "tool", name: "lookup", arguments: ~s({"key":"capital"})},
          %{action: "submit", result: %{answer: "Paris"}}
        ]
      end)

    lm = action_lm(actions)
    program = DSEx.rlm("question -> answer", lm: lm, tools: [tool], max_iterations: 3)

    assert {:ok, prediction} = DSEx.Predict.RLM.call(program, %{question: "capital?"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
  end

  defp assert_code_act_json_tool_arguments(tool) do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{tool: "lookup", arguments: ~s({"key":"capital"})},
          %{program: "observation"}
        ]
      end)

    lm = action_lm(actions)
    program = DSEx.code_act("question -> answer", [tool], lm: lm, max_iters: 3)

    assert {:ok, prediction} = DSEx.Predict.CodeAct.call(program, %{question: "capital?"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
  end

  defp action_lm(actions) do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn
            [action | rest] -> {action, rest}
            [] -> {%{tool_calls: []}, []}
          end)
        end
      ]
    }
  end
end
