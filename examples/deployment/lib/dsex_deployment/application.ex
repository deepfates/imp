defmodule DSExDeployment.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [{DSExDeployment.ProgramServer, []}]
    Supervisor.start_link(children, strategy: :one_for_one, name: DSExDeployment.Supervisor)
  end
end
