defmodule DSExDeployment.MixProject do
  use Mix.Project

  def project do
    [app: :dsex_deployment, version: "0.1.0", elixir: "~> 1.17", deps: deps()]
  end

  def application do
    [extra_applications: [:logger], mod: {DSExDeployment.Application, []}]
  end

  defp deps do
    case System.get_env("DSEX_PATH") do
      nil -> [{:dsex, "~> 0.1"}]
      path -> [{:dsex, path: path}]
    end
  end
end
