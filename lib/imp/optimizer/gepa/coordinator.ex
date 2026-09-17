defmodule Imp.Optimizer.GEPA.Coordinator do
  @moduledoc false

  @supervisor Imp.UnlinkedTaskSupervisor

  def run(items, timeout, fun) when is_list(items) and is_function(fun, 1) do
    run(items, timeout, max(length(items), 1), fun)
  end

  def run(items, timeout, max_concurrency, fun)
      when is_list(items) and is_integer(max_concurrency) and max_concurrency > 0 and
             is_function(fun, 1) do
    run_report(items, timeout, max_concurrency, fun, false).results
  end

  def run_with_report(items, timeout, max_concurrency, fun)
      when is_list(items) and is_integer(max_concurrency) and max_concurrency > 0 and
             is_function(fun, 1) do
    run_report(items, timeout, max_concurrency, fun, true)
  end

  defp run_report(items, timeout, max_concurrency, fun, fail_fast) do
    deadline = deadline(timeout)
    snapshot = Imp.Settings.snapshot()

    state = %{
      queue: Enum.with_index(items) |> Enum.map(fn {item, index} -> {index, item} end),
      active: %{},
      results: %{},
      dispatched: 0,
      terminal_index: nil,
      fail_fast: fail_fast
    }

    state = schedule(state, deadline, max_concurrency, snapshot, fun)

    %{
      results: Enum.map(0..(length(items) - 1)//1, &Map.fetch!(state.results, &1)),
      dispatched: state.dispatched,
      terminal_index: state.terminal_index
    }
  end

  # Deadline arithmetic lives in Imp.Deadline so that core modules such as
  # Imp.Evaluate and the LM clients do not depend on this optimizer internal.
  # These delegates keep the deadline helpers reachable from the Coordinator.
  defdelegate current_deadline, to: Imp.Deadline, as: :current

  @doc false
  defdelegate remaining(deadline), to: Imp.Deadline

  @doc false
  defdelegate with_deadline(timeout, fun), to: Imp.Deadline

  defdelegate deadline(timeout), to: Imp.Deadline, as: :resolve

  defp schedule(state, deadline, max_concurrency, snapshot, fun) do
    state = launch_available(state, deadline, max_concurrency, snapshot, fun)

    cond do
      map_size(state.active) == 0 and state.queue == [] ->
        state

      expired?(deadline) ->
        timeout(state)

      true ->
        receive_result(state, deadline, max_concurrency, snapshot, fun)
    end
  end

  defp launch_available(state, deadline, max_concurrency, snapshot, fun) do
    cond do
      state.queue == [] or map_size(state.active) >= max_concurrency or expired?(deadline) ->
        state

      true ->
        [{index, item} | queue] = state.queue
        owner = self()

        task =
          Task.Supervisor.async_nolink(@supervisor, fn ->
            guarded(owner, snapshot, deadline, fn -> fun.(item) end)
          end)

        state = %{
          state
          | queue: queue,
            active: Map.put(state.active, task.ref, {index, task}),
            dispatched: state.dispatched + 1
        }

        launch_available(state, deadline, max_concurrency, snapshot, fun)
    end
  end

  defp receive_result(state, deadline, max_concurrency, snapshot, fun) do
    wait = remaining(deadline)

    receive do
      {ref, result} when is_map_key(state.active, ref) ->
        if expired?(deadline) do
          timeout(state)
        else
          {{index, _task}, active} = Map.pop(state.active, ref)
          Process.demonitor(ref, [:flush])
          state = %{state | active: active, results: Map.put(state.results, index, result)}

          if state.fail_fast and terminal?(result) do
            terminate(state, index)
          else
            schedule(state, deadline, max_concurrency, snapshot, fun)
          end
        end

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.active, ref) ->
        {{index, _task}, active} = Map.pop(state.active, ref)
        result = {:error, {:task_exit, reason}}
        state = %{state | active: active, results: Map.put(state.results, index, result)}
        terminate(state, index)
    after
      wait -> timeout(state)
    end
  end

  defp timeout(%{active: active} = state) when map_size(active) > 0 do
    {index, _task} = active |> Map.values() |> Enum.min_by(&elem(&1, 0))
    state = %{state | results: Map.put(state.results, index, {:error, :timeout})}
    terminate(state, index)
  end

  defp timeout(%{queue: [{index, _item} | _]} = state) do
    state = %{state | results: Map.put(state.results, index, {:error, :timeout})}
    terminate(state, index)
  end

  defp terminate(state, terminal_index) do
    results =
      Enum.reduce(state.active, state.results, fn {_ref, {index, task}}, results ->
        _ = Task.shutdown(task, :brutal_kill)
        Map.put_new(results, index, {:error, :cancelled})
      end)

    results =
      Enum.reduce(state.queue, results, fn {index, _item}, results ->
        Map.put_new(results, index, {:error, :cancelled})
      end)

    %{state | active: %{}, queue: [], results: results, terminal_index: terminal_index}
  end

  defp terminal?({:error, _reason}), do: true
  defp terminal?({:ok, result}), do: terminal?(result)
  defp terminal?(%{status: :error}), do: true
  defp terminal?(_result), do: false

  defp expired?(deadline), do: Imp.Deadline.expired?(deadline)

  defp guarded(owner, snapshot, deadline, fun) do
    Process.flag(:trap_exit, true)
    guardian = self()
    owner_monitor = Process.monitor(owner)
    result_ref = make_ref()

    {worker, worker_monitor} =
      :erlang.spawn_opt(
        fn ->
          Imp.Deadline.bind(deadline)

          result =
            try do
              {:ok, Imp.Settings.with_snapshot(snapshot, fun)}
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
