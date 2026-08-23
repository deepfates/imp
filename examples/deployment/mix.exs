defmodule ImpDeployment.MixProject do
  use Mix.Project

  def project do
    [app: :imp_deployment, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application do
    [extra_applications: [:logger], mod: {ImpDeployment.Application, []}]
  end

  defp deps do
    case System.get_env("IMP_PATH") do
      nil -> [{:imp, github: "deepfates/imp", tag: "v0.3.1"}]
      path -> [{:imp, path: path}]
    end
  end
end
