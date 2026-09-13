defmodule Mix.Tasks.WorkspaceAgent.Acp do
  @shortdoc "Run the workspace research agent over stdio ACP"

  use Mix.Task

  @impl true
  def run(_args), do: WorkspaceAgent.run()
end
