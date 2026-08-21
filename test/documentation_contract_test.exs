defmodule DocumentationContractTest do
  use ExUnit.Case, async: true

  # Release-claims gate (dee-6yen hardening). Docs may state a Hex release as
  # present-tense fact only when hex.pm actually serves the claimed version.
  # While the docs honestly say publication is pending, this needs no network:
  # it asserts the pending marker instead. The moment a doc claims "published
  # on Hex" or links hexdocs.pm/imp WITHOUT a pending qualifier, the test
  # shells out to `mix hex.info imp` and fails unless the claim verifies — so
  # premature claims fail everywhere (offline included, deliberately: an
  # unverifiable release claim is exactly the defect), and when the owner
  # publishes, re-pinning the docs is a deliberate act done with network.
  @release_claim_files ["README.md", "RELEASE_NOTES.md", "CHANGELOG.md"]
  @release_claim_patterns [
    ~r{hexdocs\.pm/imp(?![\w-])},
    ~r{hex\.pm/packages/imp(?![\w-])},
    ~r/(published|available|released)\s+(on|to)\s+Hex\b/i
  ]
  @pending_qualifiers ~r/not yet|pending|will become|will be|becomes|once it is|until|prepared as/i

  test "docs claim a completed Hex release only if hex.pm confirms the claimed version" do
    files = @release_claim_files ++ Path.wildcard("docs/**/*.md")

    claims =
      for file <- files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Enum.any?(@release_claim_patterns, &Regex.match?(&1, line)),
          not Regex.match?(@pending_qualifiers, line),
          do: {file, number, String.trim(line)}

    if claims == [] do
      # Never pass vacuously: while nothing claims a release, the front door
      # must carry the honest pending state (dee-6yen step 1 wording).
      assert File.read!("README.md") =~ "not yet published to Hex",
             "no doc claims a Hex release, but README.md also lost its honest " <>
               "pending-publication statement; state one or the other"
    else
      version = Mix.Project.config() |> Keyword.fetch!(:version)
      {out, status} = System.cmd("mix", ["hex.info", "imp"], stderr_to_stdout: true)

      assert status == 0 and out =~ version,
             "these lines state a Hex release as present-tense fact:\n" <>
               Enum.map_join(claims, "\n", fn {f, n, l} -> "  #{f}:#{n}: #{l}" end) <>
               "\nbut `mix hex.info imp` cannot confirm version #{version} " <>
               "(exit #{status}): #{String.trim(out)}\nEither the claim is premature " <>
               "(restate it as pending) or you are offline while re-pinning release " <>
               "docs — verify with network (dee-6yen)"
    end
  end

  @documented_module_allowlist MapSet.new([
                                 "Imp.Optimize",
                                 "Imp.Optimizer",
                                 "Imp.TaskSupervisor",
                                 "Imp.UnlinkedTaskSupervisor"
                               ])

  test "coverage matrix describes current evidence instead of closed planning tickets" do
    body = File.read!("docs/internal/COVERAGE_MATRIX.md")

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

  test "API guide is the canonical signature type DSL reference" do
    body = File.read!("docs/API_GUIDE.md")

    for spelling <-
          ~w(string str integer int float number boolean bool datetime object map dict array enum class yes_no short_span numeric_span) do
      assert body =~ "`#{spelling}", "missing signature type spelling #{spelling}"
    end

    assert body =~ "custom Pydantic-style model and tuple types are not part"
    assert File.read!("README.md") =~ "docs/API_GUIDE.md#signature-type-dsl"
    assert File.read!("docs/GLOSSARY.md") =~ "API_GUIDE.md#signature-type-dsl"
  end

  test "user-facing docs keep the default HTTP transport out of the public vocabulary" do
    docs =
      ["README.md" | Path.wildcard("docs/*.md") ++ Path.wildcard("livebooks/*.livemd")]
      |> Enum.map_join("\n", &File.read!/1)

    assert docs =~ "Imp.HTTP"
    refute docs =~ "Imp.HTTP.Hackneyless"
  end

  test "release criteria are expressed as current product evidence, not historical tickets" do
    body = File.read!("docs/maintainers/RELEASE.md")

    refute_closed_ticket_refs(body)
    refute body =~ "The production release scope is tracked under ticket"
    refute body =~ "tk ready -T imp"

    assert body =~ "All unfinished work and dependencies live in `tk`"
    assert body =~ ~r/Markdown must not carry a\s+parallel roadmap/
    assert body =~ "mix production.check"
    assert body =~ "mix benchmark.dashboard.ready"
    assert body =~ "mix livebook.execute.check"
    assert body =~ "benchmarks/claims.json"
  end

  test "parity validation program describes evidence lanes instead of ticket bookkeeping" do
    body = File.read!("docs/internal/PARITY_VALIDATION_PROGRAM.md")

    refute_closed_ticket_refs(body)
    refute body =~ "Ticket:"
    refute body =~ "regressions have tickets"
  end

  test "adapter fidelity audit names upstream semantics and Imp evidence" do
    body = File.read!("docs/internal/ADAPTER_FIDELITY.md")
    readme = File.read!("docs/README.md")
    contributing = File.read!("CONTRIBUTING.md")

    assert contributing =~ "authority order is deliberately narrow"
    refute readme =~ "ADAPTER_FIDELITY.md"
    assert body =~ "DSPy `ChatAdapter` uses `[[ ## field_name ## ]]` delimiters"
    assert body =~ "JSON fallback"
    assert body =~ "Imp.Adapter.JSON.lm_opts/2"
    assert body =~ "Imp.Clients.ReqLLM"
    assert body =~ "Intentional Deviations"
    assert body =~ "the semantic contract (field names, delimiter structure"

    # Lock the honest byte-parity claim (dee-8zev): the doc must state the
    # measured byte-parity AND that it is enforced — so it can neither drift back
    # to the stale "not byte-identical" underclaim nor inflate to an unqualified
    # overclaim without a deliberate, test-visible edit.
    assert body =~ "byte-identical to DSPy 3.2.1"
    assert body =~ "enforced per-PR in CI"
  end

  test "the executable Livebook proof stays off the reader's front doors" do
    refute File.read!("README.md") =~ "mix livebook.execute.check"
    refute File.read!("docs/README.md") =~ "mix livebook.execute.check"
    assert File.read!("CONTRIBUTING.md") =~ "mix livebook.execute.check"
    assert File.read!("docs/maintainers/GATES.md") =~ "mix livebook.execute.check"
  end

  test "internal process vocabulary stays off user surfaces" do
    # CONFORMANCE.md is the receipts appendix, promoted from the conformance
    # program; evidence vocabulary ("authority", "differential") is its
    # subject matter, not a leak. EVIDENCE.md is the public definition of the
    # C0-C5 ladder (owner ruling 2026-07-17: the ladder IS the maturity
    # story), so the vocabulary is its subject matter too — everywhere else
    # it stays banned.
    user_surfaces =
      ["README.md" | Path.wildcard("docs/*.md") ++ Path.wildcard("livebooks/*.livemd")] --
        ["docs/CONFORMANCE.md", "docs/EVIDENCE.md"]

    # "differential" left off the ban list deliberately: "executable
    # differential tests" is the public conformance claim, not process vocab.
    banned = ~r/\bC1\b|authorit|\badmitted\b|tranche|fixture/i

    offenders =
      for path <- user_surfaces,
          match = Regex.run(banned, File.read!(path)),
          do: {path, hd(match)}

    assert offenders == [],
           "internal vocabulary leaked onto user surfaces: #{inspect(offenders)}"
  end

  test "learner-facing docs do not foreground maintainer evidence commands" do
    learner_text =
      ["README.md", "docs/README.md" | Path.wildcard("livebooks/*.livemd")]
      |> Enum.map_join("\n", &File.read!/1)

    refute learner_text =~ "mix evidence.check"
  end

  test "README opens with a real provider call and routes into the learning path" do
    readme = File.read!("README.md")
    learning = File.read!("docs/LEARNING_PATH.md")
    docs = File.read!("docs/README.md")

    assert readme =~ "typed Elixir program"
    assert readme =~ "Imp.req_llm"
    assert readme =~ "OPENAI_API_KEY"
    assert readme =~ "docs/LEARNING_PATH.md"
    assert readme =~ "docs/TUTORIAL_TICKET_ROUTING.md"
    # The front door shows a real model call, never the deterministic test double.
    refute readme =~ "Imp.LM.Static"
    # No quality-gate plumbing on the front door.
    refute readme =~ "test/learning_path_contract_test.exs"
    assert learning =~ "Imp.context/2"
    assert learning =~ "Imp.LM.Static"
    assert docs =~ "livebooks/01_real_lm_front_door.livemd"
    refute readme =~ "05_real_lm_wow_path"
  end

  test "docs teach the cutover Livebook sequence with real LM first" do
    readme = File.read!("README.md")
    docs = File.read!("docs/README.md")
    api = File.read!("docs/API_GUIDE.md")
    philosophy = File.read!("docs/PHILOSOPHY.md")

    assert readme =~ "Learning Path"
    assert docs =~ "## Learn the complete path with one example"
    assert readme =~ "docs/LEARNING_PATH.md"
    assert docs =~ "[01 Real LM Front Door](../livebooks/01_real_lm_front_door.livemd)"
    assert docs =~ "[05 Operate And Live Checks](../livebooks/05_operate_and_live_checks.livemd)"

    for concept <- ["signature", "program", "prediction", "example", "metric", "optimizer"] do
      assert api =~ concept
    end

    assert philosophy =~ "signature, program, call"

    refute readme =~ "01_programming_not_prompting"
    refute docs =~ "05 Real LM Wow Path"
  end

  test "canonical API guide teaches the react/rlm spectrum, not a resident agent runtime" do
    body = File.read!("docs/API_GUIDE.md")

    assert body =~ "## Tools stay typed and policy-controlled"
    assert body =~ "`react/3` is the upstream-shaped fail-fast loop"
    assert body =~ "`react_v2/3` records unknown"
    assert body =~ "`avatar/3`\nruns one typed action"
    refute body =~ "Imp.Agent"
  end

  test "API guide explains public program choices without duplicating the reference" do
    body = File.read!("docs/API_GUIDE.md")

    assert body =~ "Imp.best_of_n/3"
    assert body =~ "Imp.refine/3"
    assert body =~ "Imp.parallel/3"
    assert body =~ "Imp.knn/3"
    assert body =~ "Imp.nearest/2"
    assert body =~ "## Choose a program shape for the failure mode you need to control"
    assert body =~ "generated module reference is the exhaustive"
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
    compiled = Imp.optimize!(qa_program, optimizer, trainset, devset)

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

    assert api =~ "Imp.req_llm"
    assert api =~ "Advanced provider jobs, resumable batches, and protocol details live"
    assert api =~ "Operations Reference"
    refute api =~ "OpenAITrainer.new"
    refute api =~ "DatabricksTrainer"

    assert advanced =~ "## Protocol Clients"
    assert advanced =~ "Imp.Retrievers.HTTP.new"
    assert advanced =~ "Imp.Clients.OpenAITrainer.new"
    assert advanced =~ ~r/do not\s+train models in-process/
    assert advanced =~ "Network-facing protocol clients share the same transport boundary"
    assert advanced =~ "accepts an HTTP transport module or an arity-4 callback"

    assert advanced =~
             "SFT trainer options accept `nil`, a trainer\nmodule, a configured trainer struct, or an arity-3 callback"

    assert advanced =~
             "GRPO requires a trainer module or struct because its reinforcement\nlifecycle spans start, status, step, termination, and artifact callbacks"
  end

  test "GEPA documentation distinguishes the canonical program and artifact surfaces" do
    api = File.read!("docs/API_GUIDE.md")
    advanced = File.read!("docs/ADVANCED.md")
    coverage = File.read!("docs/internal/COVERAGE_MATRIX.md")
    parity = File.read!("docs/internal/PARITY_VALIDATION_PROGRAM.md")

    assert api =~ "## Optimize Anything uses the same selection discipline for other artifacts"
    assert api =~ "Imp.Optimize.Anything.run/3"
    assert api =~ "Imp.Optimize.Anything.best_candidate"
    assert api =~ "The validation set chooses a candidate"
    assert api =~ "GEPA and COPRO do not fabricate local proposals"
    assert advanced =~ "public frontend delegates to the production GEPA engine"
    assert advanced =~ "Current implementation fidelity is pinned to GEPA v0.1.4"
    assert advanced =~ "earlier comparisons\nagainst the v0.1.1 checkout are kept as history"
    assert coverage =~ "GEPA-style reflection"
    assert parity =~ "GEPA-style optimizer rows"
  end

  test "cold learning path distinguishes portable programs from selected parameter artifacts" do
    learning = File.read!("docs/LEARNING_PATH.md")

    assert learning =~ "## 8. Persist Programs Or Selected Parameters, Not Secrets"
    assert learning =~ "There are two restart paths."
    assert learning =~ "Imp.Optimizer.Artifact.from_optimized_program(selected"
    assert learning =~ "Imp.Optimizer.Artifact.write!(artifact"
    assert learning =~ "Imp.Optimizer.Artifact.read!()"
    assert learning =~ "Imp.Optimizer.Artifact.apply(fresh_router)"
    assert learning =~ "%Imp.Optimizer.Report{} = Imp.Optimizer.Report.fetch(deployed)"
    assert learning =~ "Imp.Optimizer.GEPA.compile_with_artifact/5"
    assert learning =~ "It does not carry your module,\nLMs, adapters, callbacks, credentials"

    assert learning =~
             "Artifact\nreproduction proves deployment behavior, not held-out improvement"
  end

  test "instruction optimizer docs define durable run-level resume boundaries" do
    ops = File.read!("docs/OPERATIONS_REFERENCE.md")
    fidelity = File.read!("docs/internal/INSTRUCTION_OPTIMIZER_FIDELITY.md")

    assert ops =~ "`max_trials:` and the compile-time `max_steps:` cap only the new work"
    assert ops =~ "Completed boundaries are not replayed"
    assert ops =~ "not signatures, authentication,\nencryption, or a sandbox"
    assert fidelity =~ "## Durable Run-Level Resume"
    assert fidelity =~ "A trial is the atomic boundary"
    assert fidelity =~ "every completed finalist evaluation"
    assert fidelity =~ "### Rebinding And Trust Boundary"
  end

  test "embedding documentation names the deterministic baseline and provider shape contract" do
    api = File.read!("docs/API_GUIDE.md")
    coverage = File.read!("docs/internal/COVERAGE_MATRIX.md")

    assert api =~ "Imp.Embeddings.BagOfWords"
    assert api =~ "Dataset\nloaders and embedding providers"
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
    ops = File.read!("docs/OPERATIONS_REFERENCE.md")

    assert api =~ "artifact_path = \"/secure/support-router-parameters.json\""
    refute api =~ "tmp/program.json"
    assert api =~ "Operations Reference"
    assert ops =~ "point Imp at trusted services you own"
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
    compiled = Imp.optimize!(program, optimizer, trainset, devset)

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

    # Mirrors the API guide: the RAG program stays dynamic (context-scoped LM)
    # because a Static-pinned program can no longer be saved (dee-i3s4 / P03).
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
    assert %Imp.Predict.RAG{retriever: %Imp.Retrieve.Memory{}} = Imp.Saving.load!(path)
  end

  test "API guide Optimize Anything example produces an improving result" do
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

  test "API guide MCP import example returns ordinary Imp tools" do
    # Mirrors docs/API_GUIDE.md "MCP Import": spec dialect (camelCase
    # "inputSchema", optional description per the MCP spec Tool definition).
    catalog =
      Imp.MCP.Catalog.new([
        %{
          "name" => "lookup",
          "inputSchema" => %{"required" => ["key"]},
          "run" => & &1
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
