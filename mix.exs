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
        extras: [
          "README.md",
          "docs/README.md",
          "docs/DSEX_PHILOSOPHY.md",
          "docs/PRIOR_ART.md",
          "docs/ARCHITECTURE.md",
          "docs/API_GUIDE.md",
          "docs/ADVANCED.md",
          "docs/BENCHMARK_TRUTH.md",
          "docs/PRODUCTION_OPERATIONS.md",
          "docs/COVERAGE_MATRIX.md",
          "docs/RELEASE_CRITERIA.md",
          "livebooks/01_programming_not_prompting.livemd",
          "livebooks/02_evaluate_and_optimize.livemd",
          "livebooks/03_agents_tools_mcp_rlm.livemd",
          "livebooks/04_production_and_live_provider.livemd"
        ]
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
      preferred_envs: [
        "production.check": :test,
        "public_surface.check": :test,
        "integration.check": :test,
        "protocol.check": :test,
        "protocol.training.check": :test,
        "protocol.retriever.check": :test,
        "protocol.mcp.check": :test,
        "benchmark.truth.check": :test,
        "benchmark.live.check": :test,
        "benchmark.parity.check": :test,
        "benchmark.parity.full": :test,
        "live.check": :test,
        "quality.check": :test
      ]
    ]
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
      licenses: ["MIT"],
      links: %{
        "Source" => "https://github.com/deepfates/dsex"
      }
    ]
  end

  defp aliases do
    [
      "public_surface.check": ["test test/public_surface_test.exs"],
      "production.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp",
        "benchmark.truth.check",
        "docs"
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
      "benchmark.truth.check": [
        "test test/benchmark_truth_test.exs"
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
      ],
      "live.check": [
        "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
      ],
      "quality.check": [
        "credo --only warning"
      ]
    ]
  end
end
