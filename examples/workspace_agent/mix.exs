defmodule WorkspaceAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :workspace_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl]]
  end

  defp deps do
    [imp_dependency()]
  end

  defp imp_dependency do
    case System.get_env("IMP_PATH") do
      path when is_binary(path) and path != "" -> {:imp, path: path}
      _unset -> {:imp, path: "../.."}
    end
  end
end
