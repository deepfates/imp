defmodule DocumentationContractTest do
  use ExUnit.Case, async: true

  @documented_module_allowlist MapSet.new([
                                 "DSEx.Optimize",
                                 "DSEx.Optimizer",
                                 "DSEx.TaskSupervisor",
                                 "DSEx.UnlinkedTaskSupervisor"
                               ])

  test "coverage matrix describes current evidence instead of closed planning tickets" do
    body = File.read!("docs/COVERAGE_MATRIX.md")

    refute_closed_ticket_refs(body)
    refute body =~ "integration gate should"
    refute body =~ "integration gate required"
    refute body =~ "integration gate needed"
    refute body =~ "DSEx.Embeddings.Hash"
    refute body =~ "DSEx.MCP.InProcess"
    refute body =~ "DSEx.MCP.HTTP`"
    refute body =~ "DSEx.MCP.Stdio`"
    refute body =~ "DSEx.MCP.StreamableHTTP`"
    refute body =~ "before closing"
    refute body =~ "waiting on live release evidence"

    assert body =~ "mix integration.check"
    assert body =~ "mix protocol.training.check"
    assert body =~ "mix protocol.check"
    assert body =~ "DSEx.Embeddings.BagOfWords"
    assert Code.ensure_loaded?(DSEx.Embeddings.BagOfWords)
    assert body =~ "DSEx.MCP.Catalog"
    assert body =~ "DSEx.MCP.HTTPClient"
    assert body =~ "DSEx.MCP.StdioClient"
    assert body =~ "DSEx.MCP.StreamableHTTPClient"
    assert Code.ensure_loaded?(DSEx.MCP.Catalog)
    assert Code.ensure_loaded?(DSEx.MCP.HTTPClient)
    assert Code.ensure_loaded?(DSEx.MCP.StdioClient)
    assert Code.ensure_loaded?(DSEx.MCP.StreamableHTTPClient)
  end

  test "documented DSEx module references resolve to loadable modules" do
    missing =
      documented_module_references()
      |> Enum.reject(&MapSet.member?(@documented_module_allowlist, &1))
      |> Enum.reject(fn name ->
        name
        |> module_from_string()
        |> Code.ensure_loaded?()
      end)

    assert missing == []
  end

  test "user-facing docs keep the default HTTP transport out of the public vocabulary" do
    docs =
      ["README.md" | Path.wildcard("docs/*.md") ++ Path.wildcard("livebooks/*.livemd")]
      |> Enum.map_join("\n", &File.read!/1)

    assert docs =~ "DSEx.HTTP"
    refute docs =~ "DSEx.HTTP.Hackneyless"
  end

  test "release criteria are expressed as current product evidence, not historical tickets" do
    body = File.read!("docs/RELEASE_CRITERIA.md")

    refute_closed_ticket_refs(body)
    refute body =~ "The production release scope is tracked under ticket"
    refute body =~ "tk ready -T dsex"

    assert body =~ ~r/Historical planning tickets are not release\s+criteria/
    assert body =~ "tk ready | rg '^de-'"
    assert body =~ "mix production.check"
    assert body =~ "mix benchmark.dashboard.full"
    assert body =~ "mix livebook.execute.check"
    assert body =~ "docs/BENCHMARK_CATALOG.md"
  end

  test "parity validation program describes evidence lanes instead of ticket bookkeeping" do
    body = File.read!("docs/PARITY_VALIDATION_PROGRAM.md")

    refute_closed_ticket_refs(body)
    refute body =~ "Ticket:"
    refute body =~ "regressions have tickets"
  end

  test "user-facing docs name the executable Livebook proof" do
    assert File.read!("README.md") =~ "mix livebook.execute.check"
    assert File.read!("docs/README.md") =~ "mix livebook.execute.check"
    assert File.read!("docs/PRODUCTION_OPERATIONS.md") =~ "mix livebook.execute.check"
  end

  test "learner-facing docs do not foreground maintainer evidence commands" do
    learner_text =
      ["README.md", "docs/README.md" | Path.wildcard("livebooks/*.livemd")]
      |> Enum.map_join("\n", &File.read!/1)

    refute learner_text =~ "mix evidence.check"
  end

  test "README teaches the new-app onboarding path" do
    body = File.read!("README.md")

    assert body =~ "mix new qa_bot --sup"
    assert body =~ "DSEx.LM.Static"
    assert body =~ "DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat]"
    assert body =~ "OPENAI_MODEL"
  end

  test "README distinguishes ReAct programs from agent runtimes in the quick path" do
    body = File.read!("README.md")

    assert body =~ "### Tools And ReAct"
    assert body =~ "react =\n  DSEx.react"
    assert body =~ "DSEx.Agent"
    refute body =~ "### Tools And Agents"
    refute body =~ "agent =\n  DSEx.react"
  end

  test "API guide teaches facade-first composition helpers" do
    body = File.read!("docs/API_GUIDE.md")

    assert body =~ "DSEx.multi_chain_comparison/2"
    assert body =~ "DSEx.best_of_n/3"
    assert body =~ "DSEx.refine/3"
    assert body =~ "DSEx.parallel/3"
    assert body =~ "DSEx.knn/3"
    assert body =~ "DSEx.nearest/2"
    assert body =~ "## Composition Helpers"
  end

  test "README common workflow snippets compose as one coherent path" do
    typed_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{sentiment: "positive", confidence: 0.9} end]
    }

    signature =
      DSEx.signature(
        "text -> sentiment: enum[positive,negative], confidence: number",
        "Classify the sentiment of the text."
      )

    typed_program = DSEx.predict(signature, lm: typed_lm, adapter: DSEx.Adapter.JSON)

    assert {:ok, typed_prediction} = DSEx.call(typed_program, %{text: "DSEx is useful."})
    assert DSEx.get(typed_prediction, :sentiment) == "positive"
    assert DSEx.get(typed_prediction, :confidence) == 0.9

    qa_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    qa_program = DSEx.predict("question -> answer", lm: qa_lm)

    trainset = [
      DSEx.example(question: "Eiffel Tower city?", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    assert %DSEx.Evaluate.Result{score: 1.0} = DSEx.evaluate(qa_program, devset, metric)

    optimizer = DSEx.Optimizer.RandomSearch.new(metric, candidates: 2, demos_per_candidate: 1)
    compiled = DSEx.optimize(qa_program, optimizer, trainset, devset)

    assert %DSEx.Optimizer.Report{optimizer: :random_search} =
             DSEx.Optimizer.Report.fetch(compiled)

    tool_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        end
      ]
    }

    lookup =
      DSEx.tool(:lookup, "lookup facts", fn %{query: "capital-france"} ->
        "Paris"
      end)

    agent =
      DSEx.react("question -> answer: short_span", [lookup],
        lm: tool_lm,
        tool_policy: [:lookup, :submit]
      )

    assert {:ok, agent_prediction} = DSEx.call(agent, %{question: "Capital of France?"})
    assert DSEx.get(agent_prediction, :answer) == "Paris"
  end

  test "API guide keeps protocol clients out of the normal provider path" do
    api = File.read!("docs/API_GUIDE.md")
    advanced = File.read!("docs/ADVANCED.md")

    assert api =~ "The normal provider path for inference is `DSEx.req_llm/2`"
    assert api =~ "Advanced Protocol Clients"
    assert api =~ "Explicit `lm:` values are checked when the program is built"
    assert api =~ "configured `%{module: module, opts:\nkeyword}` map"
    assert api =~ "module exporting `format/3` and `parse/3`"
    refute api =~ "OpenAITrainer.new"
    refute api =~ "DatabricksTrainer"

    assert advanced =~ "## Protocol Clients"
    assert advanced =~ "DSEx.Retrievers.HTTP.new"
    assert advanced =~ "DSEx.Clients.OpenAITrainer.new"
    assert advanced =~ ~r/do not\s+train models in-process/
    assert advanced =~ "Network-facing protocol clients share the same transport boundary"
    assert advanced =~ "accepts an HTTP transport module or an arity-4 callback"

    assert advanced =~
             "Trainer options accept `nil`, a trainer module, a configured trainer struct, or\nan arity-3 callback"
  end

  test "GEPA documentation is precise about DSEx-native scope" do
    api = File.read!("docs/API_GUIDE.md")
    advanced = File.read!("docs/ADVANCED.md")
    coverage = File.read!("docs/COVERAGE_MATRIX.md")
    parity = File.read!("docs/PARITY_VALIDATION_PROGRAM.md")

    assert api =~ "Elixir-native reflective optimizer"
    assert api =~ "not a wrapper around Python GEPA"
    assert api =~ "proposer_lm:"
    assert api =~ "reject malformed\nvalues when the optimizer is built or run"
    assert advanced =~ "not a Python GEPA wrapper"
    assert advanced =~ "does\nnot imply paper-scale benchmark results"
    assert coverage =~ "GEPA-style reflection"
    assert parity =~ "GEPA-style optimizer rows"
  end

  test "embedding documentation names the deterministic baseline and provider shape contract" do
    api = File.read!("docs/API_GUIDE.md")
    coverage = File.read!("docs/COVERAGE_MATRIX.md")

    assert api =~ "BagOfWords` is deterministic and local"
    assert api =~ "Production semantic embeddings"
    assert api =~ "one numeric vector for each input text"
    assert coverage =~ "deterministic local baseline"
    assert coverage =~ "one numeric vector per input text"
  end

  test "streaming response structs are deliberate public vocabulary" do
    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(DSEx.Streaming.Messages)
           )

    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(DSEx.Streaming.Messages.StreamResponse)
           )

    assert match?(
             {:docs_v1, _, _, _, %{"en" => _}, _, _},
             Code.fetch_docs(DSEx.Streaming.Messages.StreamListener)
           )
  end

  test "core LM structs are deliberate public vocabulary" do
    for module <- [
          DSEx.Core.Message,
          DSEx.Core.System,
          DSEx.Core.User,
          DSEx.Core.Assistant,
          DSEx.Core.Developer,
          DSEx.Core.ToolCall,
          DSEx.Core.ToolResult,
          DSEx.Core.LMConfig,
          DSEx.Core.LMRequest,
          DSEx.Core.LMResponse
        ] do
      assert match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
    end
  end

  test "API guide distinguishes runnable snippets from external-service sketches" do
    api = File.read!("docs/API_GUIDE.md")

    assert api =~ "Path.join(System.tmp_dir!(), \"dsex-program.json\")"
    refute api =~ "tmp/program.json"

    assert api =~ "This is an external\nservice sketch"
    assert api =~ "point DSEx at trusted services you own"
  end

  test "API guide ReAct example is executable with a deterministic tool-calling LM" do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    lm = %{
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

    lookup =
      DSEx.tool(
        :lookup,
        "lookup facts",
        fn %{query: "capital-france"} -> "Paris" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program = DSEx.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])

    assert {:ok, prediction} =
             DSEx.call(program, %{question: "What is the capital of France?"})

    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "API guide basic Predict and ChainOfThought examples are executable" do
    predict_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program =
      "question -> answer: short_span"
      |> DSEx.signature("Answer with the shortest correct span. Do not explain.")
      |> DSEx.predict(lm: predict_lm)

    assert {:ok, pred} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(pred, :answer) == "Paris"

    cot_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{reasoning: "add two and two", answer: "4"} end]
    }

    cot = DSEx.chain_of_thought("question -> answer", lm: cot_lm)

    assert {:ok, cot_pred} = DSEx.call(cot, %{question: "2+2?"})
    assert DSEx.get(cot_pred, :reasoning) == "add two and two"
    assert DSEx.get(cot_pred, :answer) == "4"
  end

  test "API guide evaluate and optimize examples are executable through the facade" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "Capital of France?", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "Eiffel Tower city?", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    assert %DSEx.Evaluate.Result{score: 1.0} = DSEx.evaluate(program, devset, metric)

    optimizer = DSEx.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
    compiled = DSEx.optimize(program, optimizer, trainset, devset)

    assert %DSEx.Optimizer.Report{optimizer: :random_search} =
             DSEx.Optimizer.Report.fetch(compiled)
  end

  test "API guide Save And Load example uses a portable program" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-doc-save-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = DSEx.predict("question -> answer")

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.Predict{} = DSEx.Saving.load!(path)
  end

  test "API guide RAG example retrieves context, records metadata, and stays portable" do
    docs = [
      %{text: "France has capital Paris."},
      %{text: "Germany has capital Berlin."}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris.",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    retriever = DSEx.Retrieve.Memory.new(docs, k: 1)

    program =
      "question, context -> answer"
      |> DSEx.predict(lm: lm)
      |> DSEx.rag(retriever, k: 1)

    assert {:ok, prediction} = DSEx.call(program, %{question: "capital France"})
    assert DSEx.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-doc-rag-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.RAG{retriever: %DSEx.Retrieve.Memory{}} = DSEx.Saving.load!(path)
  end

  test "API guide Optimize.Anything and GEPA examples produce improving reports" do
    artifact = DSEx.Optimize.Anything.new_artifact(:config, "mode=slow")

    report =
      DSEx.Optimize.Anything.optimize(
        artifact,
        fn artifact, _examples ->
          if artifact.text =~ "mode=fast", do: 1.0, else: 0.0
        end,
        trials: 1,
        mutation_fn: fn _artifact, _trial, _seed -> "mode=fast" end
      )

    assert report.baseline.score == 0.0
    assert report.best.score == 1.0
    assert report.best.artifact.text =~ "mode=fast"

    prompt = DSEx.Optimize.Anything.new_artifact(:prompt, "Base")

    gepa_report =
      DSEx.Optimize.GEPA.optimize(
        prompt,
        fn artifact, examples ->
          %{
            per_example_scores:
              Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
            asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
          }
        end,
        examples: ["Paris", "concise"],
        dev_examples: ["Paris"],
        generations: 2,
        mutation_fn: fn _artifact, asi, _generation -> {:replace, Enum.join(asi, " ")} end
      )

    assert gepa_report.best.aggregate_score >= gepa_report.baseline.aggregate_score
    assert gepa_report.metadata.frontier_size >= 1
  end

  test "API guide MCP import example returns ordinary DSEx tools" do
    catalog =
      DSEx.MCP.Catalog.new([
        %{
          name: :lookup,
          description: "lookup",
          input_schema: %{required: [:key]},
          run: & &1
        }
      ])

    [tool] = DSEx.MCP.import_tools(catalog)

    assert tool.name == :lookup
    assert {:ok, [^tool]} = DSEx.Tool.validate_tools([tool])
    assert {:error, message} = DSEx.Tool.validate_tools([:not_a_tool])
    assert message =~ "expected a list of DSEx.Tool structs"
    assert DSEx.Tool.call(tool, %{key: "value"}) == %{key: "value"}
  end

  test "API guide streaming example collects predictions and parses incremental fields" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.Streaming.stream(program, %{question: "q"}) |> Enum.to_list() == [
             "P",
             "a",
             "r",
             "i",
             "s"
           ]

    assert DSEx.Streaming.incremental_fields(
             ["[[ ## answer ## ]]Paris", "[[ ## rationale ## ]]lookup"],
             "question -> answer, rationale"
           ) == [
             %{field: :answer, value: "Paris"},
             %{field: :rationale, value: "lookup"}
           ]
  end

  defp refute_closed_ticket_refs(body) do
    refute body =~ "de-wrnz"
    refute body =~ "de-i8cc"
    refute body =~ "de-qvwf"
    refute body =~ "de-i4o5"
    refute body =~ "de-ztx7"
    refute body =~ "de-vge9"
    refute body =~ "de-t0c8"
    refute body =~ "de-dd3k"
  end

  defp documented_module_references do
    (["README.md"] ++ Path.wildcard("docs/*.md") ++ Path.wildcard("livebooks/*.livemd"))
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/DSEx(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
      |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp module_from_string(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end
end
