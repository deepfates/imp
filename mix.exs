defmodule Imp.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "Imp",
      source_url: "https://github.com/deepfates/imp",
      description: "Declarative self-improving language-model programs for Elixir.",
      package: package(),
      docs: [
        main: "Imp",
        extras: ["README.md", "CHANGELOG.md"] ++ product_docs() ++ livebooks(),
        filter_modules: &public_doc_module?/2
      ],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
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
          "benchmark.truth.check": :test,
          "benchmark.live.check": :test,
          "benchmark.dashboard": :test,
          "benchmark.dashboard.full": :test,
          "benchmark.dashboard.telos": :test,
          "benchmark.dashboard.telos.full": :test,
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
      {:ex_doc, "~> 0.35", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      files: package_files(),
      licenses: ["MIT"],
      links: %{
        "Source" => "https://github.com/deepfates/imp"
      }
    ]
  end

  defp package_files do
    excluded_lib =
      Path.wildcard("lib/mix/tasks/imp.benchmark*.ex") ++
        Path.wildcard("lib/mix/tasks/imp.identity*.ex") ++
        Path.wildcard("lib/mix/tasks/imp.gate_evidence.ex") ++
        Path.wildcard("lib/mix/tasks/imp.reproductions.ex") ++
        Path.wildcard("lib/imp/benchmark*.ex") ++
        Path.wildcard("lib/imp/benchmark_truth/**/*.ex") ++
        Path.wildcard("lib/imp/reproduction_registry.ex") ++
        Path.wildcard("lib/imp/identity_*.ex") ++
        Path.wildcard("lib/imp/identity_progress/**/*.ex") ++
        [
          "lib/imp/optimizer/playbook/campaign.ex",
          "lib/imp/optimizer/playbook/equation_search.ex"
        ]

    (Path.wildcard("lib/**/*.ex") -- excluded_lib) ++
      Path.wildcard("examples/deployment/**/*") ++
      product_docs() ++
      livebooks() ++
      [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "mix.exs"
      ]
  end

  defp product_docs do
    [
      "docs/README.md",
      "docs/LEARNING_PATH.md",
      "docs/GLOSSARY.md",
      "docs/IMP_PHILOSOPHY.md",
      "docs/PRIOR_ART.md",
      "docs/RESEARCH_LANDSCAPE.md",
      "docs/ARCHITECTURE.md",
      "docs/IDENTITY_COMPATIBILITY.md",
      "docs/API_GUIDE.md",
      "docs/TUTORIAL_EXAMPLE_PARITY.md",
      "docs/ADVANCED.md",
      "docs/REACT_V2_FIDELITY.md",
      "docs/RLM_FIDELITY.md",
      "docs/INSTRUCTION_OPTIMIZER_FIDELITY.md",
      "docs/COMBEE_FIDELITY.md",
      "docs/AX_DIFFERENTIAL.md",
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
    module_name = Atom.to_string(module)

    not Enum.any?(
      [
        "Elixir.Imp.Benchmark",
        "Elixir.Imp.Benchmarks",
        "Elixir.Mix.Tasks.Imp.Benchmark"
      ],
      &String.starts_with?(module_name, &1)
    )
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
      "public_surface.check": ["test test/public_surface_test.exs"],
      "production.check": [
        "format --check-formatted",
        "clean",
        "compile --warnings-as-errors",
        "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package",
        "benchmark.failure_campaign.check",
        "package.check",
        "livebook.check",
        "docs.clean",
        "docs"
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
        "test test/package_contract_test.exs",
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
      "quality.check": [
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
        "benchmark.operations_stress.check",
        "benchmark.failure_campaign.check",
        "benchmark.overhead.check",
        "benchmark.search.check",
        "benchmark.optimizer_lift.check",
        "benchmark.instruction_optimizer.contract.check",
        "benchmark.gepa_replication.check",
        "benchmark.fast_slow.check",
        "benchmark.optimize_anything.check",
        "benchmark.rag_tool_agent.check",
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
        "imp.benchmark.failure_campaign --iterations 10 --out tmp/failure-campaign"
      ],
      "benchmark.overhead.check": [
        "imp.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --out tmp/overhead --max-ratio 50.0"
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
        "imp.benchmark.gepa_contract --out tmp/gepa-v011-contract"
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
      "benchmark.rlm.check": [
        "imp.benchmark.rlm --data test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/rlm-benchmark"
      ],
      "benchmark.rlm.contract.check": [
        "imp.benchmark.rlm_contract --cases test/fixtures/rlm_contract_cases.json --out tmp/rlm-contract-current"
      ],
      "benchmark.live_matrix": [
        "imp.benchmark.live_matrix --in benchmarks/results/imp-dspy-parity-campaign-*.json --out tmp/live-matrix"
      ],
      "benchmark.hotpotqa_analysis": [
        "imp.benchmark.hotpotqa_analysis"
      ],
      "benchmark.dashboard": [
        "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/results --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard"
      ],
      "benchmark.dashboard.full": [
        "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/results --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard --require-full"
      ],
      "benchmark.dashboard.telos": [
        "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/results --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard"
      ],
      "benchmark.dashboard.telos.full": [
        "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/results --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard --require-full"
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
