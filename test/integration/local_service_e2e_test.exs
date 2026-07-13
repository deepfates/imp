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

  test "RAG answers through a real local HTTP retriever service" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
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
      module: DSEx.LM.Static,
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

    retriever = DSEx.Retrievers.HTTP.new(base_url <> "/retrieve")
    program = DSEx.predict("question, context -> answer", lm: lm) |> DSEx.rag(retriever, k: 1)

    devset = [
      DSEx.example(question: "capital France", answer: "Paris") |> DSEx.with_inputs(:question),
      DSEx.example(question: "capital Germany", answer: "Berlin") |> DSEx.with_inputs(:question)
    ]

    result =
      devset
      |> DSEx.Evaluate.new(DSEx.Metrics.exact_match(:answer))
      |> DSEx.Evaluate.run(program)

    assert result.score == 1.0
    assert Enum.all?(result.rows, &(&1.prediction.metadata.retrieval.count == 1))
  end

  test "streaming collection preserves structured RAG output order through local HTTP retrieval" do
    base_url =
      DSEx.Test.LocalHTTP.start(fn request ->
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
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "streaming capital answer is Lisbon",
            do: %{answer: "Lisbon", citation: "local"},
            else: %{answer: "unknown", citation: "none"}
        end
      ]
    }

    retriever = DSEx.Retrievers.HTTP.new(base_url <> "/retrieve")

    program =
      DSEx.predict("question, context -> answer, citation", lm: lm)
      |> DSEx.rag(retriever, k: 1)

    assert DSEx.Streaming.collect(program, %{question: "streaming capital"}) == "Lisbonlocal"

    assert Enum.take(DSEx.Streaming.stream(program, %{question: "streaming capital"}), 6) ==
             ~w(L i s b o n)
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
    script =
      Path.join(
        System.tmp_dir!(),
        "dsex-mcp-#{System.unique_integer([:positive, :monotonic])}-#{System.system_time(:nanosecond)}.exs"
      )

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
      System.find_executable("elixir")
      |> DSEx.MCP.StdioClient.new(
        args: ["-pa", Path.join([Mix.Project.build_path(), "lib", "jason", "ebin"]), script],
        timeout: 15_000
      )
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

  test "optimized programs save load rebind and evaluate end to end" do
    trainset = [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "France capital?", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    program = DSEx.predict("question -> answer")

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(program, trainset)

    path =
      Path.join(System.tmp_dir!(), "dsex-compiled-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(compiled, path)

    loaded = DSEx.Saving.load!(path)
    File.rm(path)

    report = DSEx.Optimizer.Report.fetch(loaded)
    assert %DSEx.Optimizer.Report{optimizer: :labeled_few_shot} = report
    assert [%{example: %DSEx.Example{} = example, selected?: true}] = report.candidates
    assert DSEx.Example.get(example, :answer) == "Paris"

    lm = %{
      module: DSEx.LM.Static,
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
      DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
        devset
        |> DSEx.Evaluate.new(DSEx.Metrics.exact_match(:answer))
        |> DSEx.Evaluate.run(loaded)
      end)

    assert result.score == 1.0
  end

  test "file dataset drives local RAG evaluation and few-shot improvement end to end" do
    path = Path.join(System.tmp_dir!(), "dsex-rag-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, """
    {"question":"capital France","answer":"Paris","context":"France has capital Paris."}
    {"question":"capital Germany","answer":"Berlin","context":"Germany has capital Berlin."}
    {"question":"capital Italy","answer":"Rome","context":"Italy has capital Rome."}
    {"question":"capital Spain","answer":"Madrid","context":"Spain has capital Madrid."}
    """)

    on_exit(fn -> File.rm(path) end)

    examples = DSEx.Datasets.hotpotqa(path)
    dataset = DSEx.Datasets.Dataset.new(examples, train: 0.5)

    docs =
      Enum.map(examples, fn example ->
        %{text: DSEx.Example.get(example, :context), source: DSEx.Example.get(example, :question)}
      end)

    retriever = DSEx.Retrieve.Memory.new(docs, k: 1)

    lm = %{
      module: DSEx.LM.Static,
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

    base = DSEx.predict("question, context -> answer", lm: lm)
    rag = DSEx.rag(base, retriever, k: 1)

    evaluator = DSEx.Evaluate.new(dataset.dev, DSEx.Metrics.exact_match(:answer))
    baseline = DSEx.Evaluate.run(evaluator, rag)

    assert baseline.score == 1.0
    assert [%{prediction: prediction}] = baseline.rows
    assert prediction.metadata.retrieval.count == 1

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(base, dataset.train)
      |> DSEx.rag(retriever, k: 1)

    optimized = DSEx.Evaluate.run(evaluator, compiled)

    assert optimized.score == 1.0

    assert %DSEx.Optimizer.Report{optimizer: :labeled_few_shot} =
             DSEx.Optimizer.Report.fetch(compiled.program)

    save_path =
      Path.join(System.tmp_dir!(), "dsex-rag-compiled-#{System.unique_integer([:positive])}.json")

    assert :ok = DSEx.Saving.save!(compiled, save_path)
    loaded = DSEx.Saving.load!(save_path)
    File.rm(save_path)

    reloaded =
      DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat], fn ->
        DSEx.Evaluate.run(evaluator, loaded)
      end)

    assert reloaded.score == 1.0

    assert %DSEx.Optimizer.Report{optimizer: :labeled_few_shot} =
             DSEx.Optimizer.Report.fetch(loaded.program)
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
