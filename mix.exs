defmodule DSEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :dsex,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "DSEx",
      source_url: "https://github.com/deepfates/dsex",
      description: "Declarative self-improving language-model programs for Elixir.",
      package: package(),
      docs: [
        main: "DSEx",
        extras: ["README.md"] ++ product_docs() ++ livebooks(),
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
      mod: {DSEx.Application, []}
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
          "benchmark.live_matrix": :test,
          "dsex.benchmark.hotpotqa_analysis": :test,
          "benchmark.hotpotqa_analysis": :test,
          "benchmark.optimizer_lift.check": :test,
          "benchmark.overhead.check": :test,
          "benchmark.rag_tool_agent.check": :test,
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
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
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
        "Source" => "https://github.com/deepfates/dsex"
      }
    ]
  end

  defp package_files do
    excluded_lib =
      Path.wildcard("lib/mix/tasks/dsex.benchmark*.ex") ++
        Path.wildcard("lib/mix/tasks/dsex.gate_evidence.ex") ++
        Path.wildcard("lib/dsex/benchmark*.ex") ++
        Path.wildcard("lib/dsex/benchmark_truth/**/*.ex")

    (Path.wildcard("lib/**/*.ex") -- excluded_lib) ++
      product_docs() ++
      livebooks() ++
      [
        ".formatter.exs",
        "README.md",
        "mix.exs"
      ]
  end

  defp product_docs do
    [
      "docs/README.md",
      "docs/LEARNING_PATH.md",
      "docs/GLOSSARY.md",
      "docs/DSEX_PHILOSOPHY.md",
      "docs/PRIOR_ART.md",
      "docs/ARCHITECTURE.md",
      "docs/API_GUIDE.md",
      "docs/ADVANCED.md",
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
        "Elixir.DSEx.Benchmark",
        "Elixir.DSEx.Benchmarks",
        "Elixir.Mix.Tasks.Dsex.Benchmark"
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
        "compile --warnings-as-errors",
        "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package",
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
        "test test/package_contract_test.exs",
        "cmd mix hex.build --unpack --output tmp/package-check"
      ],
      "livebook.check": [
        "test.livebooks --path livebooks"
      ],
      "livebook.execute.check": [
        "test.livebooks --path livebooks --execute"
      ],
      "quality.check": [
        "credo --only warning",
        "hex.audit"
      ],
      "gate.package.evidence": [
        "dsex.gate_evidence --gate product_package --mix-task package.check --out tmp/gate-evidence"
      ],
      "gate.livebook.evidence": [
        "dsex.gate_evidence --gate livebook_execute --mix-task livebook.execute.check --out tmp/gate-evidence"
      ],
      "gate.protocol.evidence": [
        "dsex.gate_evidence --gate protocol_gates --mix-task protocol.check --out tmp/gate-evidence"
      ],
      "gate.live_provider.evidence": [
        "dsex.gate_evidence --gate live_provider_smoke --mix-task live.check --env-file .env --env LIVE_PROVIDER=1 --out tmp/gate-evidence"
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
        "benchmark.truth.check",
        "benchmark.trace.check",
        "benchmark.operations_stress.check",
        "benchmark.overhead.check",
        "benchmark.optimizer_lift.check",
        "benchmark.rag_tool_agent.check"
      ],
      "benchmark.truth.check": [
        "test test/benchmark_truth_test.exs",
        "dsex.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease,ifbench_instruction_following,hard_math --full --out tmp/benchmark-truth-local",
        "dsex.benchmark.run --colors tmp/benchmark-truth-local/colors-test-0-6.jsonl --iris tmp/benchmark-truth-local/iris-test-0-6.jsonl --iris-typo tmp/benchmark-truth-local/iris_typo-test-0-3.jsonl --heart-disease tmp/benchmark-truth-local/heart_disease-test-0-4.jsonl --ifbench-instruction-following tmp/benchmark-truth-local/ifbench_instruction_following-test-0-3.jsonl --hard-math tmp/benchmark-truth-local/hard_math-test-0-3.jsonl --max-examples 6 --out tmp/benchmark-truth-local-results",
        "dsex.benchmark.integrity --gsm8k test/fixtures/benchmarks/gsm8k-small.jsonl --hotpotqa test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/benchmark-integrity --require-clean"
      ],
      "benchmark.catalog": [
        "dsex.benchmark.catalog --format json --out tmp/benchmark-catalog.json"
      ],
      "benchmark.trace.check": [
        "dsex.benchmark.trace --out tmp/golden-trace"
      ],
      "benchmark.operations_stress.check": [
        "dsex.benchmark.operations_stress --out tmp/operations-stress"
      ],
      "benchmark.overhead.check": [
        "dsex.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --out tmp/overhead --max-ratio 50.0"
      ],
      "benchmark.optimizer_lift.check": [
        "dsex.benchmark.optimizer_lift --out tmp/optimizer-lift"
      ],
      "benchmark.rag_tool_agent.check": [
        "dsex.benchmark.rag_tool_agent --out tmp/rag-tool-agent"
      ],
      "benchmark.live_matrix": [
        "dsex.benchmark.live_matrix --in benchmarks/results/dsex-dspy-parity-campaign-*.json --out tmp/live-matrix"
      ],
      "benchmark.hotpotqa_analysis": [
        "dsex.benchmark.hotpotqa_analysis"
      ],
      "benchmark.dashboard": [
        "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --rag-tool-agent-dir tmp/rag-tool-agent --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard"
      ],
      "benchmark.dashboard.full": [
        "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --rag-tool-agent-dir tmp/rag-tool-agent --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard --require-full"
      ],
      "benchmark.live.check": [
        "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
        "dsex.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2 --live"
      ],
      "benchmark.parity.check": [
        "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
        "dsex.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2"
      ],
      "benchmark.parity.full": [
        "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data",
        "dsex.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl --max-examples 7405"
      ]
    ]
  end

  defp benchmark_tasks_available? do
    File.exists?("lib/mix/tasks/dsex.benchmark.run.ex")
  end

  defp source_checkout_gates_available? do
    File.exists?("test/package_contract_test.exs")
  end

  defp clean_docs(_args), do: File.rm_rf!("doc")
end
