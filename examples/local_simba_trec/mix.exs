defmodule LocalSIMBATRECMixProject do
  use Mix.Project

  def project do
    [
      app: :local_simba_trec,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:imp, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
