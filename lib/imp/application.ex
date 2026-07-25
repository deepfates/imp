defmodule Imp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Imp.Settings,
      Imp.Cache,
      Imp.Tasks.Admission,
      {Task.Supervisor, name: Imp.TaskSupervisor},
      {Task.Supervisor, name: Imp.UnlinkedTaskSupervisor},
      {Registry, keys: :unique, name: Imp.Clients.MLXLMDeployment.Registry},
      {DynamicSupervisor, name: Imp.Clients.MLXLMDeployment.Supervisor, strategy: :one_for_one},
      {DynamicSupervisor,
       name: Imp.Optimize.Anything.StateStoreSupervisor, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Imp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
