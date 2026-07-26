defmodule Imp.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp,
      version: "0.2.1",
      elixir: "~> 1.19",
      name: "Imp",
      source_url: "https://github.com/deepfates/imp",
      description: "Declarative self-improving language-model programs for Elixir.",
      package: package(),
      docs: [
        main: "Imp",
        assets: %{"assets" => "assets"},
        api_reference: true,
        extras:
          ["README.md", "CHANGELOG.md", "RELEASE_NOTES.md"] ++ product_docs() ++ livebooks(),
        filter_modules: &public_doc_module?/2,
        skip_undefined_reference_warnings_on: &skip_filtered_doc_reference?/1,
        skip_code_autolink_to: &skip_filtered_doc_reference?/1
      ],
      start_permanent: Mix.env() == :prod,
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
      "production.check": :test,
      "fast.check": :test,
      "heavy.check": :test,
      "campaign.check": :test,
      "docs.check": :test,
      "parity.check": :test,
      "public_surface.check": :test,
      "integration.check": :test,
      "protocol.check": :test,
      "protocol.training.check": :test,
      "protocol.retriever.check": :test,
      "protocol.mcp.check": :test,
      "live.check": :test,
      "livebook.check": :test,
      "livebook.execute.check": :test,
      "package.check": :test,
      "quality.check": :test
    ]

    if benchmark_tasks_available?() do
      base_preferred_envs ++
        [
          "evidence.check": :test,
          "benchmark.failure_campaign.check": :test,
          "benchmark.truth.check": :test,
          "benchmark.live.check": :test,
          "benchmark.dashboard": :test,
          "benchmark.dashboard.ready": :test,
          "benchmark.dashboard.telos": :test,
          "benchmark.dashboard.telos.ready": :test,
          "benchmark.live_matrix": :test,
          "imp.benchmark.hotpotqa_analysis": :test,
          "benchmark.hotpotqa_analysis": :test,
          "benchmark.optimizer_lift.check": :test,
          "benchmark.instruction_optimizer.contract.check": :test,
          "benchmark.gepa.contract.check": :test,
          "benchmark.gepa_replication.check": :test,
          "benchmark.fast_slow.check": :test,
          "benchmark.overhead.check": :test,
          "benchmark.search.check": :test,
          "benchmark.rag_tool_agent.check": :test,
          "benchmark.bfcl_scorer.check": :test,
          "benchmark.copro_isolation.check": :test,
          "benchmark.rag_tool_failure.check": :test,
          "benchmark.rlm.check": :test,
          "benchmark.rlm.contract.check": :test,
          "reproduction.check": :test,
          "benchmark.parity.check": :test,
          "benchmark.parity.full": :test,
          "upstream_fidelity.check": :test
        ]
    else
      base_preferred_envs
    end
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:jaxon, "~> 2.0.8"},
      {:jsv, "~> 0.21"},
      {:nimble_options, "~> 1.1"},
      {:req, "~> 0.6"},
      {:req_llm, "~> 1.17"},
      {:telemetry, "~> 1.3"},
      {:bandit, "~> 1.0", only: :test},
      {:plug, "~> 1.15", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.35", only: [:dev, :test], runtime: false}
    ]
  end

  defp dialyzer do
    [
      # PLTs live in a stable directory so CI can cache them across runs.
      plt_core_path: "priv/plts/core",
      plt_local_path: "priv/plts/local",
      plt_add_apps: [:mix, :ex_unit],
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
    runtime_source_files() ++
      Path.wildcard("examples/deployment/**/*") ++
      Path.wildcard("examples/local_gepa_banking77/**/*") ++
      Path.wildcard("examples/local_grpo_banking77/**/*") ++
      Path.wildcard("examples/local_mipro_banking77/**/*") ++
      Path.wildcard("examples/provider_free_ticket_router/**/*") ++
      product_docs() ++
      livebooks() ++
      [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "RELEASE_NOTES.md",
        "assets/imp-with-cards.jpg",
        "priv/public_api.json",
        "priv/tutorial/support_tickets.json",
        "README.md",
        "mix.exs"
      ]
  end

  defp product_docs do
    [
      "docs/README.md",
      "docs/LEARNING_PATH.md",
      "docs/TUTORIAL_TICKET_ROUTING.md",
      "docs/GLOSSARY.md",
      "docs/PHILOSOPHY.md",
      "docs/IMP_FOR_DSPY_USERS.md",
      "docs/CONFORMANCE.md",
      "docs/EVIDENCE.md",
      "docs/PRIOR_ART.md",
      "docs/ARCHITECTURE.md",
      "docs/API_GUIDE.md",
      "docs/ADVANCED.md",
      "docs/OPERATIONS_REFERENCE.md",
      "docs/OBSERVABILITY.md",
      "docs/PRODUCTION_OPERATIONS.md"
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
    |> Jason.decode!()
    |> Map.fetch!("modules")
    |> MapSet.new(& &1["module"])
  end

  defp canonical_internal_modules do
    Path.join(__DIR__, "priv/public_api.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("excluded_modules")
    |> MapSet.new(& &1["module"])
  end

  # ExDoc passes nil for references that name no module (links between extras).
  defp skip_filtered_doc_reference?(nil), do: false

  defp skip_filtered_doc_reference?(reference) do
    reference = String.trim_leading(reference, "Elixir.")

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
      "production.check": [
        "format --check-formatted",
        "clean",
        "compile --warnings-as-errors",
        "legacy_identity.check",
        "test --raise --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package",
        "benchmark.failure_campaign.check",
        "package.check",
        "livebook.check",
        "docs.clean",
        "docs"
      ],
      # Quick merge signal for path-filtered CI (dee-4g0z): format + compile +
      # the deterministic unit suite (same exclusions as production.check's test
      # step), minus failure_campaign/package/livebooks/docs. No Python/Deno
      # reference runtimes required.
      "fast.check": [
        "format --check-formatted",
        "clean",
        "compile --warnings-as-errors",
        "legacy_identity.check",
        "test --raise --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package"
      ],
      # Heavy gates without the unit suite (dee-9k5m). fast.check is the sole
      # unit-suite gate in CI; production.check keeps the suite for local
      # one-shot use, but the CI production lane runs these parts instead so
      # the 110s suite is not paid twice per PR. In CI the parts run as three
      # parallel jobs (campaign.check / package.check / docs.check); this
      # alias is the serial local equivalent.
      "heavy.check": [
        "benchmark.failure_campaign.check",
        "package.check",
        "livebook.check",
        "docs.clean",
        "docs"
      ],
      # CI campaign lane (dee-9k5m): the failure campaign plus the
      # prompt-template parity gate, which needs the tmp/dspy-parity-venv
      # reference runtime the campaign CI job builds (or restores from cache).
      "campaign.check": [
        "benchmark.failure_campaign.check",
        "parity.check"
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
        # cmd, not a plain "test" step: Mix runs each task once per invocation,
        # so inside production.check (whose suite run already consumed "test")
        # a plain step would silently no-op and this gate would never execute.
        "cmd mix test test/package_contract_test.exs",
        "cmd mix hex.build --unpack --output tmp/package-check",
        "imp.package.clean_room --package tmp/package-check"
      ],
      "package.clean": [&clean_package/1],
      "livebook.check": [
        "test.livebooks --path livebooks"
      ],
      "livebook.execute.check": [
        "test.livebooks --path livebooks --execute"
      ],
      "legacy_identity.check": [
        "run scripts/legacy_identity_audit.exs"
      ],
      # Static type gate (de-xmi1). Runs in dev (PLTs are built per-env; dev
      # matches local use). Fails on any warning not pinned with a reason in
      # .dialyzer_ignore.exs, and reports ignore entries that stopped
      # matching (list_unused_filters) so the ignore file cannot rot.
      "dialyzer.check": [
        "dialyzer"
      ],
      "quality.check": [
        "legacy_identity.check",
        "credo --only warning",
        "cmd mix hex.audit"
      ],
      "gate.package.evidence": [
        "imp.gate_evidence --gate product_package --mix-task package.check --out tmp/gate-evidence"
      ],
      "gate.livebook.evidence": [
        "imp.gate_evidence --gate livebook_execute --mix-task livebook.execute.check --out tmp/gate-evidence"
      ],
      "gate.protocol.evidence": [
        "imp.gate_evidence --gate protocol_gates --mix-task protocol.check --out tmp/gate-evidence"
      ],
      "gate.live_provider.evidence": [
        "imp.gate_evidence --gate live_provider_smoke --mix-task live.check --env-file .env --env LIVE_PROVIDER=1 --out tmp/gate-evidence"
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
      "evidence.check": [
        "reproduction.check",
        "research.portfolio.check",
        "benchmark.truth.check",
        "benchmark.trace.check",
        "benchmark.failure_campaign.check",
        "benchmark.search.check",
        "benchmark.optimizer_lift.check",
        "benchmark.instruction_optimizer.contract.check",
        "benchmark.gepa_replication.check",
        "benchmark.fast_slow.check",
        "benchmark.optimize_anything.check",
        "benchmark.rag_tool_agent.check",
        "benchmark.bfcl_scorer.check",
        "benchmark.copro_isolation.check",
        "benchmark.rag_tool_failure.check",
        "benchmark.rlm.check",
        "benchmark.rlm.contract.check",
        "upstream_fidelity.check"
      ],
      "upstream_fidelity.check": [
        "imp.upstream_fidelity --out tmp/upstream-fidelity/upstream-fidelity.json --require-conformant"
      ],
      "reproduction.check": [
        "imp.reproductions --check"
      ],
      "research.portfolio.check": [
        "imp.research_portfolio --check"
      ],
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
      "benchmark.rag_tool_agent.check": [
        "imp.benchmark.rag_tool_agent --out tmp/rag-tool-agent"
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
      "benchmark.live_matrix": [
        "imp.benchmark.live_matrix --in benchmarks/runs/parity/imp-dspy-parity-campaign-*.json --out tmp/live-matrix"
      ],
      "benchmark.hotpotqa_analysis": [
        "imp.benchmark.hotpotqa_analysis"
      ],
      "benchmark.dashboard": [
        "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard"
      ],
      "benchmark.dashboard.ready": [
        "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard --require-ready"
      ],
      "benchmark.dashboard.telos": [
        "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard"
      ],
      "benchmark.dashboard.telos.ready": [
        "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard --require-ready"
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
