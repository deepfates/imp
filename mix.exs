defmodule Imp.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp,
      version: "0.5.0",
      elixir: "~> 1.19",
      name: "Imp",
      source_url: "https://github.com/deepfates/imp",
      description: "Declarative self-improving language-model programs for Elixir.",
      package: package(),
      docs: [
        main: "readme",
        assets: %{"assets" => "assets"},
        api_reference: true,
        warnings_as_errors: true,
        extras:
          ["README.md"] ++
            product_docs() ++
            repository_docs() ++ livebooks() ++ ["RELEASE_NOTES.md", "CHANGELOG.md"],
        groups_for_extras: [
          Guides: product_docs(),
          Evidence: repository_docs(),
          Livebooks: livebooks(),
          Releases: ["RELEASE_NOTES.md", "CHANGELOG.md"]
        ],
        groups_for_modules: public_api_doc_groups(),
        filter_modules: &public_doc_module?/2,
        skip_undefined_reference_warnings_on: &skip_filtered_doc_reference?/1,
        skip_code_autolink_to: &skip_filtered_doc_reference?/1
      ],
      start_permanent: Mix.env() == :prod,
      hex: [ignore_advisories: audit_ignored_advisory_ids()],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {Imp.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: preferred_envs()
    ]
  end

  defp preferred_envs do
    if source_checkout_gates_available?() do
      source_checkout_preferred_envs()
    else
      []
    end
  end

  defp source_checkout_preferred_envs do
    base_preferred_envs = [
      check: :test,
      "docs.check": :test,
      "parity.check": :test,
      "public_surface.check": :test,
      "integration.check": :test,
      "protocol.check": :test,
      "protocol.training.check": :test,
      "protocol.retriever.check": :test,
      "protocol.mcp.check": :test,
      "live.check": :test,
      "differential.check": :test,
      "livebook.check": :test,
      "livebook.execute.check": :test,
      "package.check": :test,
      "quality.check": :test
    ]

    if benchmark_tasks_available?() do
      base_preferred_envs ++
        [
          "benchmark.failure_campaign.check": :test,
          "benchmark.truth.check": :test,
          "benchmark.gepa_replication.check": :test,
          "benchmark.live.check": :test,
          "benchmark.optimizer_lift.check": :test,
          "benchmark.instruction_optimizer.contract.check": :test,
          "benchmark.gepa.contract.check": :test,
          "benchmark.fast_slow.check": :test,
          "benchmark.overhead.check": :test,
          "benchmark.search.check": :test,
          "benchmark.bfcl_scorer.check": :test,
          "benchmark.copro_isolation.check": :test,
          "benchmark.rag_tool_failure.check": :test,
          "benchmark.rlm.check": :test,
          "benchmark.rlm.contract.check": :test,
          "benchmark.parity.check": :test,
          "benchmark.parity.full": :test
        ]
    else
      base_preferred_envs
    end
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # MCP and ACP wire protocols. Both are started only by the protocol entry
      # points (`Imp.ACP.*`, a non-empty `Imp.MCP.connect/2`), never by ordinary
      # Imp boot, so neither is a runtime application here; releases that use
      # the adapters include them in :load mode (docs/PRODUCTION_OPERATIONS.md).
      # erlexec owns the process group of each local MCP server
      # (`Imp.MCP.OwnedStdio`); its application starts a port program, which is
      # why it is started on the first stdio connection and not at boot.
      {:ex_mcp, "~> 1.5", runtime: false},
      {:erlexec, "~> 2.2", runtime: false},
      {:jason, "~> 1.4"},
      {:jaxon, "~> 2.0.8"},
      {:jsv, "~> 0.21"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.6"},
      # 1.18 is the first release with :total_timeout, which bounds a call
      # under an Imp.Deadline including ReqLLM's retries (Imp.Clients.ReqLLM).
      {:req_llm, "~> 1.18"},
      {:saxy, "~> 1.6"},
      {:telemetry, "~> 1.3"},
      {:bandit, "~> 1.0", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # PLTs live in a stable directory so CI can cache them across runs.
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts/local",
      # Protocol adapters compile against ExMCP even though ordinary Imp boot
      # deliberately does not start it. Dialyzer still needs its contracts.
      plt_add_apps: [:mix, :ex_unit, :ex_mcp, :erlexec, :plug_cowboy],
      # Every entry in the ignore file carries a one-line reason.
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # bench/ and source_checkout_files/ form Imp's local research control plane.
  # They remain available in a top-level dev/test checkout. Mix compiles
  # dependencies in :prod by default, where we select the same runtime source
  # files that the Hex package ships instead of compiling local control tasks.
  defp elixirc_paths(:test), do: ["lib", "bench", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "bench"]
  defp elixirc_paths(_env), do: runtime_source_files()

  defp runtime_source_files do
    Path.wildcard("lib/**/*.ex") -- source_checkout_files()
  end

  defp source_checkout_files do
    Path.wildcard("lib/mix/tasks/**/*.ex") ++
      Path.wildcard("lib/imp/benchmark*.ex") ++
      [
        # The demo MCP servers the demo tasks and the tests run. Nothing the
        # package ships uses them, and they were its only use of Plug, which is
        # therefore not a dependency of Imp; the source checkout gets it
        # through ExMCP.
        "lib/imp/acp/demo_mcp_http_plug.ex",
        "lib/imp/acp/demo_mcp_oauth_plug.ex",
        "lib/imp/acp/demo_mcp_server.ex",
        "lib/imp/optimizer/playbook/campaign.ex",
        "lib/imp/optimizer/playbook/equation_search.ex"
      ]
  end

  defp package do
    [
      files: package_files(),
      licenses: ["MIT"],
      links: %{
        "Source" => "https://github.com/deepfates/imp",
        "Changelog" => "https://github.com/deepfates/imp/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp package_files do
    # Keep packaging and dependency compilation on one canonical runtime list.
    # Local benchmark/evidence control files remain available only to a
    # top-level dev/test checkout.
    (runtime_source_files() ++
       deployment_example_files() ++
       Path.wildcard("examples/provider_free_ticket_router/**/*") ++
       Path.wildcard("examples/workspace_agent/**/*") ++
       product_docs() ++
       livebooks() ++
       [
         ".formatter.exs",
         "CHANGELOG.md",
         "LICENSE",
         "NOTICE",
         "RELEASE_NOTES.md",
         "assets/imp-with-cards.jpg",
         "priv/public_api.json",
         "priv/tutorial/support_tickets.json",
         "README.md",
         "mix.exs"
       ])
    |> Enum.reject(&transient_package_path?/1)
  end

  defp deployment_example_files do
    [
      "examples/deployment/README.md",
      "examples/deployment/agent_optimization.exs",
      "examples/deployment/load_workflow.exs",
      "examples/deployment/mix.exs",
      "examples/deployment/mix.lock",
      "examples/deployment/run_workflow.exs",
      "examples/deployment/lib/imp_deployment/application.ex",
      "examples/deployment/lib/imp_deployment/callbacks.ex",
      "examples/deployment/lib/imp_deployment/program_server.ex",
      "examples/deployment/lib/imp_deployment/support_pipeline.ex",
      "examples/deployment/lib/imp_deployment/workflow.ex"
    ]
  end

  defp transient_package_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in ["_build", "deps"]))
  end

  defp product_docs do
    [
      "docs/LEARNING_PATH.md",
      "docs/TUTORIAL_TICKET_ROUTING.md",
      "docs/IMP_FOR_DSPY_USERS.md",
      "docs/PRODUCTION_OPERATIONS.md",
      "docs/TRAJECTORIES.md"
    ]
  end

  # Rendered into the docs but NOT shipped in the package: they describe
  # source-checkout commands a Hex consumer cannot run.
  # docs/BENCHMARKS.md is deliberately NOT here. It is almost entirely bare
  # `mix …` command spans, which ExDoc resolves to their task modules and then
  # warns about because those modules are filtered out of the public API docs.
  # It is a source-checkout document like CONTRIBUTING.md; README, EVIDENCE and
  # the case study link to it by URL.
  defp repository_docs do
    [
      "docs/CASE_STUDY_TREC.md",
      "docs/EVIDENCE.md"
    ]
  end

  defp livebooks do
    [
      "livebooks/01_real_lm_front_door.livemd",
      "livebooks/02_programming_not_prompting.livemd",
      "livebooks/03_evaluate_and_optimize.livemd",
      "livebooks/04_tools_agents_mcp_rlm.livemd",
      "livebooks/05_operate_and_live_checks.livemd"
    ]
  end

  defp public_doc_module?(module, _metadata) do
    MapSet.member?(canonical_supported_modules(), inspect(module))
  end

  defp canonical_supported_modules do
    Path.join(__DIR__, "priv/public_api.json")
    |> File.read!()
    |> :json.decode()
    |> Map.fetch!("modules")
    |> MapSet.new(& &1["module"])
  end

  defp canonical_internal_modules do
    Path.join(__DIR__, "priv/public_api.json")
    |> File.read!()
    |> :json.decode()
    |> Map.fetch!("excluded_modules")
    |> MapSet.new(& &1["module"])
  end

  defp public_api_doc_groups do
    modules =
      Path.join(__DIR__, "priv/public_api.json")
      |> File.read!()
      |> :json.decode()
      |> Map.fetch!("modules")

    # The protocol adapters are grouped by what they are rather than by their
    # support level, which `priv/public_api.json` records per module.
    {protocols, modules} =
      Enum.split_with(modules, fn %{"module" => module} ->
        module in ["Imp.ACP", "Imp.MCP"] or String.starts_with?(module, ["Imp.ACP.", "Imp.MCP."])
      end)

    by_category = Enum.group_by(modules, & &1["category"], & &1["module"])

    [
      {"Stable center", Map.get(by_category, "facade", []) ++ Map.get(by_category, "stable", [])},
      {"MCP and ACP", Enum.map(protocols, & &1["module"])},
      {"Experimental optimizers and advanced workflows",
       Map.get(by_category, "experimental", [])},
      {"Extension interfaces", Map.get(by_category, "spi", [])}
    ]
  end

  # ExDoc passes nil for references that name no module (links between extras).
  defp skip_filtered_doc_reference?(nil), do: false

  defp skip_filtered_doc_reference?(reference) do
    reference =
      reference
      |> String.replace_prefix("t:", "")
      |> String.replace_prefix("c:", "")
      |> String.replace_prefix("m:", "")
      |> String.trim_leading("Elixir.")

    reference in [
      "Imp.Adapter.JSON",
      "Imp.Clients.TRLDeployment",
      "Imp.Clients.TRLProtocol",
      "Imp.Optimizer.GEPA.Acceptance",
      "Imp.Optimizer.GEPA.BatchSampler",
      "Imp.Optimizer.Utils"
    ] or
      Enum.any?(canonical_internal_modules(), fn module_name ->
        reference == module_name or String.starts_with?(reference, module_name <> ".")
      end)
  end

  defp aliases do
    if source_checkout_gates_available?() do
      source_checkout_aliases()
    else
      []
    end
  end

  defp source_checkout_aliases do
    base_aliases = [
      "public_surface.check": [
        "imp.public_api --check",
        "test test/public_api_manifest_test.exs test/public_surface_test.exs"
      ],
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --raise --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package --exclude dspy_parity"
      ],
      # The pinned-DSPy differential suite (imp-sqkr): everything tagged
      # :dspy_parity, run after scripts/setup_dspy_parity_env.sh and
      # scripts/setup_dspy_stable_source.sh have provisioned the environment.
      "differential.check": [
        "test --raise --only dspy_parity"
      ],
      # Docs-only path for path-filtered CI (dee-4g0z): render docs + validate
      # livebooks, without the package build / campaign / Python differentials.
      "docs.check": [
        "docs.clean",
        "docs",
        "livebook.check"
      ],
      # Prompt-template fidelity gate (dee-3e4v): run the golden-trace differential
      # test (Imp vs the pinned DSPy 3.2.1 venv) so a byte-parity regression FAILS
      # the build per-PR, not only on the weekly evidence-full lane. Requires the
      # tmp/dspy-parity-venv the campaign CI job builds; runs after that setup.
      "parity.check": [
        "test --raise test/golden_trace_test.exs --include evidence_infrastructure"
      ],
      "docs.clean": [
        &clean_docs/1
      ],
      "integration.check": [
        "test --only integration test/integration"
      ],
      "protocol.check": [
        "test --include protocol_training --include protocol_retriever --include protocol_mcp test/protocol_training test/protocol_retriever test/protocol_mcp"
      ],
      "protocol.training.check": [
        "test --only protocol_training test/protocol_training"
      ],
      "protocol.retriever.check": [
        "test --only protocol_retriever test/protocol_retriever"
      ],
      "protocol.mcp.check": [
        "test --only protocol_mcp test/protocol_mcp"
      ],
      "live.check": [
        "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
      ],
      "package.check": [
        "package.clean",
        # Use a child Mix invocation so this alias remains independently
        # runnable even after another test task in the same VM.
        "cmd mix test test/package_contract_test.exs",
        "imp.package.clean_room"
      ],
      "package.clean": [&clean_package/1],
      "livebook.check": [
        "test.livebooks --path livebooks"
      ],
      "livebook.execute.check": [
        "test.livebooks --path livebooks --execute"
      ],
      # Static type gate (de-xmi1). Runs in dev (PLTs are built per-env; dev
      # matches local use). Fails on any warning not pinned with a reason in
      # .dialyzer_ignore.exs, and reports ignore entries that stopped
      # matching (list_unused_filters) so the ignore file cannot rot.
      "dialyzer.check": [
        "dialyzer"
      ],
      # Dependency advisories run through mix_audit, whose database records a
      # fixed range per advisory. mix hex.audit serves the ERLEF feed, where the
      # three open cowlib records are open-ended (introduced 2.9.0, no fixed
      # version), so it flags every cowlib release that exists including the one
      # carrying the fix. hex.audit stays in the gate for retired packages,
      # which mix_audit does not check, with those ids ignored from
      # .audit_ignore -- one file holding each id next to what was verified and
      # what retires it. Both run as child invocations: mix deps.audit stops the
      # VM when it finds something.
      "quality.check": [
        "credo --only warning",
        "cmd mix deps.audit --ignore-file .audit_ignore",
        "cmd mix hex.audit"
      ]
    ]

    if benchmark_tasks_available?() do
      base_aliases ++ benchmark_aliases()
    else
      base_aliases
    end
  end

  defp benchmark_aliases do
    [
      "benchmark.truth.check": [
        "test test/benchmark_truth_test.exs",
        "imp.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease,ifbench_instruction_following,hard_math --full --out tmp/benchmark-truth-local",
        "imp.benchmark.run --colors tmp/benchmark-truth-local/colors-test-0-6.jsonl --iris tmp/benchmark-truth-local/iris-test-0-6.jsonl --iris-typo tmp/benchmark-truth-local/iris_typo-test-0-3.jsonl --heart-disease tmp/benchmark-truth-local/heart_disease-test-0-4.jsonl --ifbench-instruction-following tmp/benchmark-truth-local/ifbench_instruction_following-test-0-3.jsonl --hard-math tmp/benchmark-truth-local/hard_math-test-0-3.jsonl --max-examples 6 --out tmp/benchmark-truth-local-results",
        "imp.benchmark.integrity --gsm8k test/fixtures/benchmarks/gsm8k-small.jsonl --hotpotqa test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/benchmark-integrity --require-clean"
      ],
      "benchmark.catalog": [
        "imp.benchmark.catalog --format json --out tmp/benchmark-catalog.json"
      ],
      "benchmark.trace.check": [
        "imp.benchmark.trace --out tmp/golden-trace"
      ],
      "benchmark.operations_stress.check": [
        "imp.benchmark.operations_stress --out tmp/operations-stress"
      ],
      "benchmark.failure_campaign.check": [
        "imp.benchmark.failure_campaign --iterations 10 --require-clean --out tmp/failure-campaign"
      ],
      "benchmark.overhead.check": [
        "imp.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --require-clean --out tmp/overhead"
      ],
      "benchmark.search.check": [
        "imp.benchmark.search --iterations 10 --max-concurrency 2 --work-ms 10 --out tmp/search-benchmark"
      ],
      "benchmark.optimizer_lift.check": [
        "imp.benchmark.optimizer_lift --out tmp/optimizer-lift"
      ],
      "benchmark.instruction_optimizer.contract.check": [
        "imp.benchmark.instruction_optimizer_contract --out tmp/instruction-optimizer-contract"
      ],
      "benchmark.gepa.contract.check": [
        "imp.benchmark.gepa_contract --out tmp/gepa-v014-contract"
      ],
      "benchmark.gepa_replication.check": [
        "imp.benchmark.gepa_replication --smoke --out tmp/gepa-replication"
      ],
      "benchmark.fast_slow.check": [
        "imp.benchmark.fast_slow --out tmp/fast-slow-protocol.json"
      ],
      "benchmark.optimize_anything.check": [
        "imp.benchmark.optimize_anything --smoke --out tmp/optimize-anything"
      ],
      "benchmark.bfcl_scorer.check": [
        "imp.benchmark.bfcl_adapted --no-require-clean --out tmp/bfcl-shaped-scorer"
      ],
      "benchmark.copro_isolation.check": [
        "imp.benchmark.copro_isolation --require-clean --out tmp/copro-isolation"
      ],
      "benchmark.rag_tool_failure.check": [
        "imp.benchmark.rag_tool_failure_differential --no-require-clean --out tmp/rag-tool-failure-differential"
      ],
      "benchmark.rlm.check": [
        "imp.benchmark.rlm --data test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/rlm-benchmark"
      ],
      "benchmark.rlm.contract.check": [
        "cmd tmp/dspy-current-venv/bin/python test/python_verify_dspy_current_target_test.py",
        "cmd tmp/dspy-current-venv/bin/python test/python_dspy_rlm_campaign_test.py",
        "cmd tmp/dspy-current-venv/bin/python test/python_dspy_rlm_wrapper_integration_test.py",
        "imp.benchmark.rlm_contract --cases test/fixtures/rlm_contract_cases.json --out tmp/rlm-contract-current"
      ],
      "benchmark.live.check": [
        "imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
        "imp.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2 --live"
      ],
      "benchmark.parity.check": [
        "imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
        "imp.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2"
      ],
      "benchmark.parity.full": [
        "imp.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data",
        "imp.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl --max-examples 7405"
      ]
    ]
  end

  # Advisory ids the quality gate accepts, read from .audit_ignore so the ids,
  # the reason each was verified to be safe to ignore, and the condition that
  # retires it live in one file that both audit steps read. Absent in a Hex
  # package checkout, where the gates do not run.
  defp audit_ignored_advisory_ids do
    path = Path.expand(".audit_ignore", __DIR__)

    if File.regular?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    else
      []
    end
  end

  defp benchmark_tasks_available? do
    File.exists?("lib/mix/tasks/imp.benchmark.run.ex")
  end

  defp source_checkout_gates_available? do
    File.exists?("test/package_contract_test.exs")
  end

  defp clean_docs(_args), do: File.rm_rf!("doc")

  defp clean_package(_args) do
    File.rm_rf!("tmp/package-check")
    File.rm_rf!("tmp/package-clean-room")
  end
end
