defmodule LocalServiceE2ETest do
  use ExUnit.Case

  @moduletag :integration

  test "HTTP retriever performs a real local HTTP request and maps documents" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
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

    retriever = Imp.Retrievers.HTTP.new(base_url <> "/retrieve")

    assert {:ok, [%{text: "BEAM document", score: 0.9, metadata: %{"source" => "local"}}]} =
             Imp.Retrieve.retrieve(retriever, "beam", k: 2)
  end

  test "RAG answers through a real local HTTP retriever service" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/retrieve"
        payload = Jason.decode!(request.body)

        doc =
          case payload["query"] do
            "capital France" ->
              %{text: "France has capital Paris.", score: 1.0, source: "local"}

            "capital Germany" ->
              %{text: "Germany has capital Berlin.", score: 1.0, source: "local"}
          end

        {200, %{documents: [doc]}}
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "France has capital Paris" -> %{answer: "Paris"}
            prompt =~ "Germany has capital Berlin" -> %{answer: "Berlin"}
            true -> %{answer: "unknown"}
          end
        end
      ]
    }

    retriever = Imp.Retrievers.HTTP.new(base_url <> "/retrieve")
    program = Imp.predict("question, context -> answer", lm: lm) |> Imp.rag(retriever, k: 1)

    devset = [
      Imp.example(question: "capital France", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "capital Germany", answer: "Berlin") |> Imp.with_inputs(:question)
    ]

    result =
      devset
      |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer))
      |> Imp.Evaluate.run(program)

    assert result.score == 1.0
    assert Enum.all?(result.rows, &(&1.prediction.metadata.retrieval.count == 1))
  end

  test "streaming collection preserves structured RAG output order through local HTTP retrieval" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        assert request.method == "POST"
        assert request.path == "/retrieve"
        assert %{"query" => "streaming capital", "k" => 1} = Jason.decode!(request.body)

        {200,
         %{
           documents: [
             %{text: "The streaming capital answer is Lisbon.", score: 1.0, source: "local"}
           ]
         }}
      end)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "streaming capital answer is Lisbon",
            do: %{answer: "Lisbon", citation: "local"},
            else: %{answer: "unknown", citation: "none"}
        end
      ]
    }

    retriever = Imp.Retrievers.HTTP.new(base_url <> "/retrieve")

    program =
      Imp.predict("question, context -> answer, citation", lm: lm)
      |> Imp.rag(retriever, k: 1)

    assert Imp.Streaming.collect(program, %{question: "streaming capital"}) == "Lisbonlocal"

    assert Enum.take(Imp.Streaming.stream(program, %{question: "streaming capital"}), 6) ==
             ~w(L i s b o n)
  end

  test "HTTP MCP client discovers and calls a local JSON-RPC tool server" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)

        case decoded["method"] do
          "server/discover" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               error: %{code: -32601, message: "Method not found"}
             }}

          "initialize" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 protocolVersion: "2025-03-26",
                 capabilities: %{tools: %{}},
                 serverInfo: %{name: "local", version: "1"}
               }
             }}

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
                     # MCP spec, Tool definition: camelCase "inputSchema".
                     inputSchema: %{
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

            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{content: [%{type: "text", text: "Paris"}]}
             }}
        end
      end)

    [tool] = base_url |> Imp.Test.MCPConnect.http!() |> Map.fetch!(:tools)

    assert tool.name == "lookup"
    assert Imp.Tool.call(tool, %{"key" => "capital"}) == "Paris"
  end

  test "stdio MCP client discovers and calls a trusted local executable" do
    script =
      Path.join(
        System.tmp_dir!(),
        "imp-mcp-#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:nanosecond)}.exs"
      )

    File.write!(script, """
    Enum.each(IO.stream(:stdio, :line), fn line ->
      request = Jason.decode!(line)
      response =
        case request["method"] do
          "server/discover" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "error" => %{"code" => -32601, "message" => "Method not found"}}
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"protocolVersion" => "2025-03-26", "capabilities" => %{"tools" => %{}}, "serverInfo" => %{"name" => "fixture", "version" => "1"}}}
          "tools/list" ->
            # MCP spec, Tool definition: camelCase "inputSchema".
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"tools" => [%{"name" => "echo", "description" => "Echo input", "inputSchema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]}}]}}
          "tools/call" ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"content" => [%{"type" => "text", "text" => request["params"]["arguments"]["text"]}]}}
          _ ->
            nil
        end

      if response, do: IO.puts(Jason.encode!(response))
    end)
    """)

    on_exit(fn -> File.rm(script) end)

    [tool] =
      System.find_executable("elixir")
      |> Imp.Test.MCPConnect.stdio!(
        args: ["-pa", Path.join([Mix.Project.build_path(), "lib", "jason", "ebin"]), script],
        timeout: 15_000
      )
      |> Map.fetch!(:tools)

    assert tool.name == "echo"
    assert Imp.Tool.call(tool, %{"text" => "hello"}) == "hello"
  end

  test "tool programs accept provider JSON string arguments end to end" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        decoded = Jason.decode!(request.body)

        case decoded["method"] do
          "server/discover" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               error: %{code: -32601, message: "Method not found"}
             }}

          "initialize" ->
            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{
                 protocolVersion: "2025-03-26",
                 capabilities: %{tools: %{}},
                 serverInfo: %{name: "local", version: "1"}
               }
             }}

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
                     # MCP spec, Tool definition: camelCase "inputSchema".
                     inputSchema: %{
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

            {200,
             %{
               jsonrpc: "2.0",
               id: decoded["id"],
               result: %{content: [%{type: "text", text: "Paris"}]}
             }}
        end
      end)

    [tool] = base_url |> Imp.Test.MCPConnect.http!() |> Map.fetch!(:tools)

    assert_react_json_tool_arguments(tool)
    assert_rlm_json_tool_arguments(tool)
    assert_code_act_json_tool_arguments(tool)
  end

  test "optimized programs save load rebind and evaluate end to end" do
    trainset = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    program = Imp.predict("question -> answer")

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)

    path =
      Path.join(System.tmp_dir!(), "imp-compiled-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(compiled, path)

    loaded = Imp.Saving.load!(path)
    File.rm(path)

    report = Imp.Optimizer.Report.fetch(loaded)
    assert %Imp.Optimizer.Report{optimizer: :labeled_few_shot} = report
    assert [%{example: %Imp.Example{} = example, selected?: true}] = report.candidates
    assert Imp.Example.get(example, :answer) == "Paris"

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "Capital of France?",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    result =
      Imp.context([lm: lm, adapter: Imp.Adapter.Chat], fn ->
        devset
        |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer))
        |> Imp.Evaluate.run(loaded)
      end)

    assert result.score == 1.0
  end

  test "file dataset drives local RAG evaluation and few-shot improvement end to end" do
    path = Path.join(System.tmp_dir!(), "imp-rag-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, """
    {"question":"capital France","answer":"Paris","context":"France has capital Paris."}
    {"question":"capital Germany","answer":"Berlin","context":"Germany has capital Berlin."}
    {"question":"capital Italy","answer":"Rome","context":"Italy has capital Rome."}
    {"question":"capital Spain","answer":"Madrid","context":"Spain has capital Madrid."}
    """)

    on_exit(fn -> File.rm(path) end)

    examples = Imp.Datasets.hotpotqa(path)
    dataset = Imp.Datasets.Dataset.new(examples, train: 0.5)

    docs =
      Enum.map(examples, fn example ->
        %{text: Imp.Example.get(example, :context), source: Imp.Example.get(example, :question)}
      end)

    retriever = Imp.Retrieve.Memory.new(docs, k: 1)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          current = prompt |> String.split("[[ ## context ## ]]") |> List.last()

          cond do
            current =~ "Germany has capital Berlin" -> %{answer: "Berlin"}
            current =~ "France has capital Paris" -> %{answer: "Paris"}
            current =~ "Italy has capital Rome" -> %{answer: "Rome"}
            current =~ "Spain has capital Madrid" -> %{answer: "Madrid"}
            true -> %{answer: "unknown"}
          end
        end
      ]
    }

    # The compiled RAG is saved, so the LM comes from context: saving refuses a
    # Static-pinned program.
    base = Imp.predict("question, context -> answer")
    rag = Imp.rag(base, retriever, k: 1)

    evaluator = Imp.Evaluate.new(dataset.dev, Imp.Metrics.exact_match(:answer))
    baseline = Imp.context([lm: lm], fn -> Imp.Evaluate.run(evaluator, rag) end)

    assert baseline.score == 1.0
    assert [%{prediction: prediction}] = baseline.rows
    assert prediction.metadata.retrieval.count == 1

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(base, dataset.train)
      |> Imp.rag(retriever, k: 1)

    optimized = Imp.context([lm: lm], fn -> Imp.Evaluate.run(evaluator, compiled) end)

    assert optimized.score == 1.0

    assert %Imp.Optimizer.Report{optimizer: :labeled_few_shot} =
             Imp.Optimizer.Report.fetch(compiled.program)

    save_path =
      Path.join(System.tmp_dir!(), "imp-rag-compiled-#{System.unique_integer([:positive])}.json")

    assert :ok = Imp.Saving.save!(compiled, save_path)
    loaded = Imp.Saving.load!(save_path)
    File.rm(save_path)

    reloaded =
      Imp.context([lm: lm, adapter: Imp.Adapter.Chat], fn ->
        Imp.Evaluate.run(evaluator, loaded)
      end)

    assert reloaded.score == 1.0

    assert %Imp.Optimizer.Report{optimizer: :labeled_few_shot} =
             Imp.Optimizer.Report.fetch(loaded.program)
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
    program = Imp.react("question -> answer", [tool], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.Predict.ReAct.call(program, %{question: "capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
  end

  defp assert_rlm_json_tool_arguments(tool) do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{code: ~S|lookup(%{key: "capital"})|},
          %{code: ~S|submit(%{answer: "Paris"})|}
        ]
      end)

    lm = action_lm(actions)
    program = Imp.rlm("question -> answer", lm: lm, tools: [tool], max_iterations: 3)

    assert {:ok, prediction} = Imp.Predict.RLM.call(program, %{question: "capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
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
    program = Imp.code_act("question -> answer", [tool], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.Predict.CodeAct.call(program, %{question: "capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
  end

  defp action_lm(actions) do
    %{
      module: Imp.LM.Static,
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
