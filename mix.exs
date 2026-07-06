defmodule Dachshund.MixProject do
  use Mix.Project

  def project do
    [
      app: :dachshund,
      version: "0.1.0",
      elixir: "~> 1.19",
      name: "Dachshund",
      source_url: "https://github.com/deepfates/dachshund",
      description: "Declarative self-improving language-model programs for Elixir.",
      package: package(),
      docs: [
        main: "Dachshund",
        extras: [
          "README.md",
          "docs/README.md",
          "docs/DACHSHUND_PHILOSOPHY.md",
          "docs/ARCHITECTURE.md",
          "docs/TERMINOLOGY.md",
          "docs/API_GUIDE.md",
          "docs/PRODUCTION_OPERATIONS.md",
          "livebooks/01_programming_not_prompting.livemd",
          "livebooks/02_evaluate_and_optimize.livemd",
          "livebooks/03_agents_tools_mcp_rlm.livemd",
          "livebooks/04_production_and_live_provider.livemd",
          "TELOS.md",
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
      mod: {Dachshund.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        "production.check": :test,
        "production.audit": :test,
        "v2.audit": :test,
        "v2.check": :test,
        "public_surface.check": :test
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
      links: %{
        "Source" => "https://github.com/deepfates/dachshund"
      }
    ]
  end

  defp aliases do
    [
      "public_surface.check": ["test test/public_surface_test.exs"],
      "production.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
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
