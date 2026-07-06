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
          "docs/V2.md",
          "docs/PRODUCTION_OPERATIONS.md",
          "livebooks/01_programming_not_prompting.livemd",
          "livebooks/02_evaluate_and_optimize.livemd",
          "livebooks/03_agents_tools_mcp_rlm.livemd",
          "livebooks/04_production_and_live_provider.livemd"
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
      mod: {DSEx.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        "production.check": :test,
        "v2.check": :test,
        "public_surface.check": :test,
        "live.check": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: [:dev, :test], runtime: false}
    ]
  end

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
        "test",
        "docs"
      ],
      "v2.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test --include v2"
      ],
      "live.check": [
        "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
      ]
    ]
  end
end
