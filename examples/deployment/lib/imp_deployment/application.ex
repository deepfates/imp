defmodule ImpDeployment.Application do
  use Application

  @impl true
  def start(_type, _args) do
    task_supervisor =
      Supervisor.child_spec(
        {Task.Supervisor, name: ImpDeployment.TaskSupervisor, max_children: max_concurrency()},
        shutdown: shutdown_timeout()
      )

    children = [task_supervisor, {ImpDeployment.ProgramServer, []}]
    Supervisor.start_link(children, strategy: :one_for_one, name: ImpDeployment.Supervisor)
  end

  defp max_concurrency do
    positive_integer_env("IMP_MAX_CONCURRENCY", System.schedulers_online())
  end

  defp shutdown_timeout do
    positive_integer_env("IMP_SHUTDOWN_TIMEOUT", 5_000)
  end

  defp positive_integer_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _other -> raise "#{name} must be a positive integer, got: #{inspect(value)}"
        end
    end
  end
end
