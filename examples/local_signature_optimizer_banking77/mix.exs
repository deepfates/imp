defmodule ImpLocalSignatureOptimizerBanking77.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp_local_signature_optimizer_banking77,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [{:imp, path: System.get_env("IMP_PATH", "../..")}]
    ]
  end
end
