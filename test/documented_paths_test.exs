defmodule DocumentedPathsTest do
  @moduledoc """
  The facade paths the guides teach, run with a scripted model: predict,
  chain of thought, typed JSON, evaluate and optimize, tools and ReAct,
  retrieval, saving, streaming, MCP import and Optimize Anything.
  """
  use ExUnit.Case, async: true

  test "typed output, evaluation, optimization and ReAct compose as one path" do
    typed_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> %{sentiment: "positive", confidence: 0.9} end
      )

    signature =
      Imp.signature(
        "text -> sentiment: enum[positive,negative], confidence: number",
        "Classify the sentiment of the text."
      )

    typed_program = Imp.predict(signature, lm: typed_lm, adapter: Imp.Adapter.JSON)

    assert {:ok, typed_prediction} = Imp.call(typed_program, %{text: "Imp is useful."})
    assert Imp.get(typed_prediction, :sentiment) == "positive"
    assert Imp.get(typed_prediction, :confidence) == 0.9

    qa_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    qa_program = Imp.predict("question -> answer", lm: qa_lm)

    trainset = [
      Imp.example(question: "Eiffel Tower city?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)

    assert %Imp.Evaluate.Result{score: 1.0} = Imp.evaluate(qa_program, devset, metric)

    optimizer =
      Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
        num_candidate_programs: 2,
        max_bootstrapped_demos: 1
      )

    compiled = Imp.optimize!(qa_program, optimizer, trainset, devset)

    assert %Imp.Optimizer.Report{optimizer: :random_search} =
             Imp.Optimizer.Report.fetch(compiled)

    tool_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        end
      )

    lookup =
      Imp.tool(:lookup, "lookup facts", fn %{"query" => "capital-france"} ->
        "Paris"
      end)

    agent =
      Imp.Predict.ReAct.new("question -> answer: short_span", [lookup],
        lm: tool_lm,
        tool_policy: [:lookup, :submit]
      )

    assert {:ok, agent_prediction} = Imp.call(agent, %{question: "Capital of France?"})
    assert Imp.get(agent_prediction, :answer) == "Paris"
  end

  test "the deterministic embedder says in its own docs that it is not a semantic model" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Imp.Embeddings.BagOfWords)

    assert doc =~ "local baseline"
    assert doc =~ "not a semantic embedding model"
    assert doc =~ "inject a real embedding provider"
  end

  test "streaming response structs are deliberate public vocabulary" do
    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(Imp.Streaming.Messages)
           )

    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(Imp.Streaming.Messages.StreamResponse)
           )

    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(Imp.Streaming.Messages.StreamListener)
           )
  end

  test "core LM structs are deliberate public vocabulary" do
    for module <- [
          Imp.Core.Message,
          Imp.Core.System,
          Imp.Core.User,
          Imp.Core.Assistant,
          Imp.Core.Developer,
          Imp.Core.LMConfig,
          Imp.Core.LMRequest,
          Imp.Core.LMResponse
        ] do
      assert match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
    end
  end

  test "the documented ReAct path executes with a deterministic tool-calling LM" do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn
            [action | rest] -> {action, rest}
            [] -> {%{tool_calls: []}, []}
          end)
        end
      )

    lookup =
      Imp.tool(
        :lookup,
        "lookup facts",
        fn %{"query" => "capital-france"} -> "Paris" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        tool_policy: [:lookup, :submit]
      )

    assert {:ok, prediction} =
             Imp.call(program, %{question: "What is the capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "the documented Predict and ChainOfThought paths execute" do
    predict_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program =
      "question -> answer: short_span"
      |> Imp.signature("Answer with the shortest correct span. Do not explain.")
      |> Imp.predict(lm: predict_lm)

    assert {:ok, pred} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(pred, :answer) == "Paris"

    cot_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> %{reasoning: "add two and two", answer: "4"} end
      )

    cot = Imp.chain_of_thought("question -> answer", lm: cot_lm)

    assert {:ok, cot_pred} = Imp.call(cot, %{question: "2+2?"})
    assert Imp.get(cot_pred, :reasoning) == "add two and two"
    assert Imp.get(cot_pred, :answer) == "4"
  end

  test "the documented evaluate and optimize path executes through the facade" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "Capital of France?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)

    assert %Imp.Evaluate.Result{score: 1.0} = Imp.evaluate(program, devset, metric)

    optimizer =
      Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
        num_candidate_programs: 4,
        max_bootstrapped_demos: 1
      )

    compiled = Imp.optimize!(program, optimizer, trainset, devset)

    assert %Imp.Optimizer.Report{optimizer: :random_search} =
             Imp.Optimizer.Report.fetch(compiled)
  end

  test "the documented save and load path uses a portable program" do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-doc-save-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = Imp.predict("question -> answer")

    assert :ok = Imp.Saving.save!(program, path)
    assert %Imp.Predict{} = Imp.Saving.read!(path)
  end

  test "the documented RAG path retrieves context, records metadata, and stays portable" do
    docs = [
      %{text: "France has capital Paris."},
      %{text: "Germany has capital Berlin."}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris.",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      )

    retriever = Imp.Retrieve.Memory.new(docs, k: 1)

    # Mirrors the API guide: the RAG program stays dynamic (context-scoped LM)
    # because saving refuses a Static-pinned program.
    program =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(retriever, k: 1)

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(program, %{question: "capital France"})
             end)

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-doc-rag-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.Saving.save!(program, path)
    assert %Imp.Predict.RAG{retriever: %Imp.Retrieve.Memory{}} = Imp.Saving.read!(path)
  end

  test "the documented Optimize Anything path produces an improving result" do
    result =
      Imp.Optimize.Anything.run(
        "mode=slow",
        fn candidate -> if(candidate =~ "mode=fast", do: 1.0, else: 0.0) end,
        config: [
          engine: [max_candidate_proposals: 1, parallel: false],
          reflection: [
            custom_candidate_proposer: fn _candidate, _component, _records, _iteration ->
              "mode=fast"
            end
          ]
        ]
      )

    assert hd(result.validation_scores) == 0.0
    assert Enum.max(result.validation_scores) == 1.0
  end

  test "the documented MCP import path returns an import with cleanup" do
    # With no servers nothing is dialed and the ExMCP application is not started.
    assert {:ok, %Imp.MCP.Import{tools: [], unavailable: []} = import} = Imp.MCP.connect([])
    assert :ok = import.cleanup.()
  end

  test "the documented streaming path collects predictions and parses incremental fields" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer", lm: lm)

    assert Imp.stream(program, %{question: "q"}) |> Enum.to_list() == [
             "P",
             "a",
             "r",
             "i",
             "s"
           ]

    assert Imp.Streaming.incremental_fields(
             ["[[ ## answer ## ]]Paris", "[[ ## rationale ## ]]lookup"],
             "question -> answer, rationale"
           ) == [
             %{field: :answer, value: "Paris"},
             %{field: :rationale, value: "lookup"}
           ]
  end
end
