defmodule DSEx.Optimizer.GEPA.Coordinator do
  @moduledoc false

  @supervisor DSEx.UnlinkedTaskSupervisor

  def run(items, timeout, fun) when is_list(items) and is_function(fun, 1) do
    run(items, timeout, max(length(items), 1), fun)
  end

  def run(items, timeout, max_concurrency, fun)
      when is_list(items) and is_integer(max_concurrency) and max_concurrency > 0 and
             is_function(fun, 1) do
    items
    |> Enum.chunk_every(max_concurrency)
    |> Enum.flat_map(&run_chunk(&1, timeout, fun))
  end

  defp run_chunk(items, timeout, fun) do
    snapshot = DSEx.Settings.snapshot()
    owner = self()

    tasks =
      Enum.map(items, fn item ->
        Task.Supervisor.async_nolink(@supervisor, fn ->
          guarded(owner, snapshot, fn -> fun.(item) end)
        end)
      end)

    tasks
    |> Task.yield_many(timeout)
    |> Enum.map(fn
      {_task, {:ok, result}} ->
        result

      {_task, {:exit, reason}} ->
        {:error, {:task_exit, reason}}

      {task, nil} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end)
  end

  defp guarded(owner, snapshot, fun) do
    Process.flag(:trap_exit, true)
    guardian = self()
    owner_monitor = Process.monitor(owner)
    result_ref = make_ref()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              {:ok, DSEx.Settings.with_snapshot(snapshot, fun)}
            rescue
              exception -> {:error, {:exception, Exception.message(exception)}}
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(guardian, {result_ref, result})
        end,
        [:link, :monitor]
      )

    try do
      receive do
        {^result_ref, result} ->
          Process.demonitor(worker_monitor, [:flush])
          result

        {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
          {:error, {:worker_exit, reason}}

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          Process.exit(worker, :kill)
          exit(:shutdown)
      end
    after
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      Process.demonitor(owner_monitor, [:flush])
    end
  end
end
