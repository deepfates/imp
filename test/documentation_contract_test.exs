defmodule DocumentationContractTest do
  use ExUnit.Case, async: true

  @documented_module_allowlist MapSet.new([
                                 "Imp.Optimize",
                                 "Imp.Optimizer",
                                 "Imp.TaskSupervisor",
                                 "Imp.UnlinkedTaskSupervisor"
                               ])

  test "coverage matrix describes current evidence instead of closed planning tickets" do
    body = File.read!("docs/COVERAGE_MATRIX.md")

    refute_closed_ticket_refs(body)
    refute body =~ "integration gate should"
    refute body =~ "integration gate required"
    refute body =~ "integration gate needed"
    refute body =~ "Imp.Embeddings.Hash"
    refute body =~ "Imp.MCP.InProcess"
    refute body =~ "Imp.MCP.HTTP`"
    refute body =~ "Imp.MCP.Stdio`"
    refute body =~ "Imp.MCP.StreamableHTTP`"
    refute body =~ "before closing"
    refute body =~ "waiting on live release evidence"

    assert body =~ "mix integration.check"
    assert body =~ "mix protocol.training.check"
    assert body =~ "mix protocol.check"
    assert body =~ "Imp.Embeddings.BagOfWords"
    assert Code.ensure_loaded?(Imp.Embeddings.BagOfWords)
    assert body =~ "Imp.MCP.Catalog"
    assert body =~ "Imp.MCP.HTTPClient"
    assert body =~ "Imp.MCP.StdioClient"
    assert body =~ "Imp.MCP.StreamableHTTPClient"
    assert Code.ensure_loaded?(Imp.MCP.Catalog)
    assert Code.ensure_loaded?(Imp.MCP.HTTPClient)
    assert Code.ensure_loaded?(Imp.MCP.StdioClient)
    assert Code.ensure_loaded?(Imp.MCP.StreamableHTTPClient)
  end

  test "documented Imp module references resolve to loadable modules" do
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

    assert docs =~ "Imp.HTTP"
    refute docs =~ "Imp.HTTP.Hackneyless"
  end

  test "release criteria are expressed as current product evidence, not historical tickets" do
    body = File.read!("docs/RELEASE_CRITERIA.md")

    refute_closed_ticket_refs(body)
    refute body =~ "The production release scope is tracked under ticket"
    refute body =~ "tk ready -T imp"

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

  test "adapter fidelity audit names upstream semantics and Imp evidence" do
    body = File.read!("docs/ADAPTER_FIDELITY.md")
    readme = File.read!("docs/README.md")

    assert readme =~ "release-evidence notes"
    refute readme =~ "ADAPTER_FIDELITY.md"
    assert body =~ "DSPy `ChatAdapter` uses `[[ ## field_name ## ]]` delimiters"
    assert body =~ "JSON fallback"
    assert body =~ "Imp.Adapter.JSON.lm_opts/2"
    assert body =~ "Imp.Clients.ReqLLM"
    assert body =~ "Intentional Deviations"
    assert body =~ "semantic: field names, delimiter structure, demo/history turn shape"
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

  test "README routes onboarding into the executable canonical learning path" do
    readme = File.read!("README.md")
    learning = File.read!("docs/LEARNING_PATH.md")
    docs = File.read!("docs/README.md")

    assert readme =~ "Program your LMs on the BEAM"
    assert readme =~ "Imp.LM.Static"
    assert readme =~ "docs/LEARNING_PATH.md"
    assert readme =~ "test/learning_path_contract_test.exs"
    assert learning =~ "Imp.context/2"
    assert learning =~ "OPENAI_MODEL"
    assert docs =~ "livebooks/01_real_lm_front_door.livemd"
    refute readme =~ "05_real_lm_wow_path"
  end

  test "docs teach the cutover Livebook sequence with real LM first" do
    readme = File.read!("README.md")
    docs = File.read!("docs/README.md")
    api = File.read!("docs/API_GUIDE.md")
    philosophy = File.read!("docs/IMP_PHILOSOPHY.md")

    assert readme =~ "canonical, self-contained route"
    assert docs =~ "## Manual Spine"
    assert readme =~ "docs/LEARNING_PATH.md"
    assert docs =~ "[01 Real LM Front Door](../livebooks/01_real_lm_front_door.livemd)"
    assert docs =~ "[05 Operate And Live Checks](../livebooks/05_operate_and_live_checks.livemd)"

    assert api =~
             "signature -> program -> call -> evaluate -> optimize -> tools/agents -> operate"

    assert philosophy =~ "signature, program, call"

    refute readme =~ "01_programming_not_prompting"
    refute docs =~ "05 Real LM Wow Path"
  end

  test "canonical API guide distinguishes ReAct programs from agent runtimes" do
    body = File.read!("docs/API_GUIDE.md")

    assert body =~ "## Tools And ReAct"
    assert body =~ "Imp.react"
    assert body =~ "Imp.Agent"
    assert body =~ "explicit Elixir agent runtime"
  end

  test "API guide teaches facade-first composition helpers" do
    body = File.read!("docs/API_GUIDE.md")

    assert body =~ "Imp.multi_chain_comparison/2"
    assert body =~ "Imp.best_of_n/3"
    assert body =~ "Imp.refine/3"
    assert body =~ "Imp.parallel/3"
    assert body =~ "Imp.knn/3"
    assert body =~ "Imp.nearest/2"
    assert body =~ "## Composition Helpers"
  end

  test "README common workflow snippets compose as one coherent path" do
    typed_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{sentiment: "positive", confidence: 0.9} end]
    }

    signature =
      Imp.signature(
        "text -> sentiment: enum[positive,negative], confidence: number",
        "Classify the sentiment of the text."
      )

    typed_program = Imp.predict(signature, lm: typed_lm, adapter: Imp.Adapter.JSON)

    assert {:ok, typed_prediction} = Imp.call(typed_program, %{text: "Imp is useful."})
    assert Imp.get(typed_prediction, :sentiment) == "positive"
    assert Imp.get(typed_prediction, :confidence) == 0.9

    qa_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

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

    optimizer = Imp.Optimizer.RandomSearch.new(metric, candidates: 2, demos_per_candidate: 1)
    compiled = Imp.optimize(qa_program, optimizer, trainset, devset)

    assert %Imp.Optimizer.Report{optimizer: :random_search} =
             Imp.Optimizer.Report.fetch(compiled)

    tool_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        end
      ]
    }

    lookup =
      Imp.tool(:lookup, "lookup facts", fn %{query: "capital-france"} ->
        "Paris"
      end)

    agent =
      Imp.react("question -> answer: short_span", [lookup],
        lm: tool_lm,
        tool_policy: [:lookup, :submit]
      )

    assert {:ok, agent_prediction} = Imp.call(agent, %{question: "Capital of France?"})
    assert Imp.get(agent_prediction, :answer) == "Paris"
  end

  test "API guide keeps protocol clients out of the normal provider path" do
    api = File.read!("docs/API_GUIDE.md")
    advanced = File.read!("docs/ADVANCED.md")

    assert api =~ "The normal provider path for inference is `Imp.req_llm/2`"
    assert api =~ "Advanced Protocol Clients"
    assert api =~ "Explicit `lm:` values are checked when the program is built"
    assert api =~ "configured `%{module: module, opts:\nkeyword}` map"
    assert api =~ "module exporting `format/3` and `parse/3`"
    refute api =~ "OpenAITrainer.new"
    refute api =~ "DatabricksTrainer"

    assert advanced =~ "## Protocol Clients"
    assert advanced =~ "Imp.Retrievers.HTTP.new"
    assert advanced =~ "Imp.Clients.OpenAITrainer.new"
    assert advanced =~ ~r/do not\s+train models in-process/
    assert advanced =~ "Network-facing protocol clients share the same transport boundary"
    assert advanced =~ "accepts an HTTP transport module or an arity-4 callback"

    assert advanced =~
             "Trainer options accept `nil`, a trainer module, a configured trainer struct, or\nan arity-3 callback"
  end

  test "GEPA documentation distinguishes the canonical program and artifact surfaces" do
    api = File.read!("docs/API_GUIDE.md")
    advanced = File.read!("docs/ADVANCED.md")
    coverage = File.read!("docs/COVERAGE_MATRIX.md")
    parity = File.read!("docs/PARITY_VALIDATION_PROGRAM.md")

    assert api =~ "## Optimize Arbitrary Artifacts"
    assert api =~ "sole\nOptimize Anything surface"
    assert api =~ "proposer_lm:"
    assert api =~ "reject malformed\nvalues when the optimizer is built or run"
    assert advanced =~ "public frontend delegates to the production GEPA engine"
    assert advanced =~ "not a claim of parity with unreleased GEPA\nmain"
    assert coverage =~ "GEPA-style reflection"
    assert parity =~ "GEPA-style optimizer rows"
  end

  test "instruction optimizer docs define durable run-level resume boundaries" do
    api = File.read!("docs/API_GUIDE.md")
    fidelity = File.read!("docs/INSTRUCTION_OPTIMIZER_FIDELITY.md")

    assert api =~ "`max_trials:` and the compile-time `max_steps:` cap only the new work"
    assert api =~ "Completed boundaries are not replayed"
    assert api =~ "not signatures, authentication,\nencryption, or a sandbox"
    assert fidelity =~ "## Durable Run-Level Resume"
    assert fidelity =~ "A trial is the atomic boundary"
    assert fidelity =~ "every completed finalist evaluation"
    assert fidelity =~ "### Rebinding And Trust Boundary"
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
          Imp.Core.ToolCall,
          Imp.Core.ToolResult,
          Imp.Core.LMConfig,
          Imp.Core.LMRequest,
          Imp.Core.LMResponse
        ] do
      assert match?({:docs_v1, _, _, _, %{"en" => _}, _, _}, Code.fetch_docs(module))
    end
  end

  test "API guide distinguishes runnable snippets from external-service sketches" do
    api = File.read!("docs/API_GUIDE.md")

    assert api =~ "Path.join(System.tmp_dir!(), \"imp-program.json\")"
    refute api =~ "tmp/program.json"

    assert api =~ "This is an external\nservice sketch"
    assert api =~ "point Imp at trusted services you own"
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

    lookup =
      Imp.tool(
        :lookup,
        "lookup facts",
        fn %{query: "capital-france"} -> "Paris" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program = Imp.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])

    assert {:ok, prediction} =
             Imp.call(program, %{question: "What is the capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "API guide basic Predict and ChainOfThought examples are executable" do
    predict_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program =
      "question -> answer: short_span"
      |> Imp.signature("Answer with the shortest correct span. Do not explain.")
      |> Imp.predict(lm: predict_lm)

    assert {:ok, pred} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(pred, :answer) == "Paris"

    cot_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{reasoning: "add two and two", answer: "4"} end]
    }

    cot = Imp.chain_of_thought("question -> answer", lm: cot_lm)

    assert {:ok, cot_pred} = Imp.call(cot, %{question: "2+2?"})
    assert Imp.get(cot_pred, :reasoning) == "add two and two"
    assert Imp.get(cot_pred, :answer) == "4"
  end

  test "API guide evaluate and optimize examples are executable through the facade" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "Capital of France?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)

    assert %Imp.Evaluate.Result{score: 1.0} = Imp.evaluate(program, devset, metric)

    optimizer = Imp.Optimizer.RandomSearch.new(metric, candidates: 4, demos_per_candidate: 1)
    compiled = Imp.optimize(program, optimizer, trainset, devset)

    assert %Imp.Optimizer.Report{optimizer: :random_search} =
             Imp.Optimizer.Report.fetch(compiled)
  end

  test "API guide Save And Load example uses a portable program" do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-doc-save-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = Imp.predict("question -> answer")

    assert :ok = Imp.Saving.save!(program, path)
    assert %Imp.Predict.Predict{} = Imp.Saving.load!(path)
  end

  test "API guide RAG example retrieves context, records metadata, and stays portable" do
    docs = [
      %{text: "France has capital Paris."},
      %{text: "Germany has capital Berlin."}
    ]

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris.",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    retriever = Imp.Retrieve.Memory.new(docs, k: 1)

    program =
      "question, context -> answer"
      |> Imp.predict(lm: lm)
      |> Imp.rag(retriever, k: 1)

    assert {:ok, prediction} = Imp.call(program, %{question: "capital France"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-doc-rag-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.Saving.save!(program, path)
    assert %Imp.Predict.RAG{retriever: %Imp.Retrieve.Memory{}} = Imp.Saving.load!(path)
  end

  test "API guide Optimize Anything example produces an improving result" do
    result =
      Imp.Optimize.Anything.run(
        "mode=slow",
        fn candidate -> if(candidate =~ "mode=fast", do: 1.0, else: 0.0) end,
        config:
          Imp.Optimize.Anything.Config.new(
            engine: [max_candidate_proposals: 1, parallel: false],
            reflection: [
              custom_candidate_proposer: fn _candidate, _component, _records, _iteration ->
                "mode=fast"
              end
            ]
          )
      )

    assert hd(result.validation_scores) == 0.0
    assert Imp.Optimize.Anything.Result.best_candidate(result) == "mode=fast"
    assert Enum.max(result.validation_scores) == 1.0
  end

  test "API guide MCP import example returns ordinary Imp tools" do
    catalog =
      Imp.MCP.Catalog.new([
        %{
          name: :lookup,
          description: "lookup",
          input_schema: %{required: [:key]},
          run: & &1
        }
      ])

    [tool] = Imp.MCP.import_tools(catalog)

    assert tool.name == :lookup
    assert {:ok, [^tool]} = Imp.Tool.validate_tools([tool])
    assert {:error, message} = Imp.Tool.validate_tools([:not_a_tool])
    assert message =~ "expected a list of Imp.Tool structs"
    assert Imp.Tool.call(tool, %{key: "value"}) == %{key: "value"}
  end

  test "API guide streaming example collects predictions and parses incremental fields" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)

    assert Imp.Streaming.stream(program, %{question: "q"}) |> Enum.to_list() == [
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
      |> then(&Regex.scan(~r/Imp(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
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
