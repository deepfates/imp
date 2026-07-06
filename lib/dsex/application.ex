defmodule DSEx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DSEx.Settings,
      DSEx.Cache,
      {Task.Supervisor, name: DSEx.TaskSupervisor},
      {Task.Supervisor, name: DSEx.UnlinkedTaskSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DSEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
