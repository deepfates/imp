defmodule LocalSIMBAFeedbackTRECMixProject do
  use Mix.Project

  def project do
    [
      app: :local_simba_feedback_trec,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: [{:imp, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
