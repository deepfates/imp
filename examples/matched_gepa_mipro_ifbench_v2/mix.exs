defmodule ImpMatchedGepaMiproIFBenchV2.MixProject do
  use Mix.Project

  def project do
    [
      app: :imp_matched_gepa_mipro_ifbench_v2,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: [{:imp, path: System.get_env("IMP_PATH", "../..")}]
    ]
  end
end
