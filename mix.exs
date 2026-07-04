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
        extras: ["README.md", "TELOS.md"]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {DspyElixir.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"DSPy" => "https://dspy.ai/"}
    ]
  end
end
