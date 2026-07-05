defmodule DspyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :dspy_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "DSPy Elixir",
      source_url: "https://github.com/deepfates/dspy_elixir",
      description:
        "An Elixir-native translation of DSPy's programming model for language models.",
      package: package(),
      docs: [
        main: "DSPy",
        extras: [
          "README.md",
          "docs/README.md",
          "docs/DSPY_PHILOSOPHY.md",
          "docs/ARCHITECTURE.md",
          "docs/API_GUIDE.md",
          "docs/PRODUCTION_OPERATIONS.md",
          "livebooks/01_programming_not_prompting.livemd",
          "livebooks/02_evaluate_and_optimize.livemd",
          "livebooks/03_agents_tools_mcp_rlm.livemd",
          "livebooks/04_production_and_live_provider.livemd",
          "TELOS.md",
          "PARITY.md",
          "PRODUCTION.md",
          "PRODUCTION_AUDIT.md",
          "ECOSYSTEM_COVERAGE.md",
          "V2.md",
          "V2_ROADMAP.md"
        ]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {DspyElixir.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        "production.check": :test,
        "production.audit": :test,
        "v2.audit": :test,
        "v2.check": :test,
        "parity.check": :test,
        "parity.generate": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"DSPy" => "https://dspy.ai/"}
    ]
  end

  defp aliases do
    [
      "parity.generate": ["run scripts/generate_parity_exports.exs"],
      "parity.check": ["run scripts/check_parity_exports.exs"],
      "production.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "parity.check",
        "production.audit",
        "test"
      ],
      "production.audit": ["run scripts/check_production_audit.exs"],
      "v2.audit": ["run scripts/check_v2_audit.exs"],
      "v2.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "v2.audit",
        "test --include v2"
      ]
    ]
  end
end
