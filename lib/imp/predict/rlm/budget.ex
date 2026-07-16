defmodule Imp.Predict.RLM.Budget do
  @moduledoc false

  use GenServer

  @type snapshot :: %{
          lm_calls: non_neg_integer(),
          reserved_lm_calls: non_neg_integer(),
          max_lm_calls: non_neg_integer(),
          max_recursion_depth_reached: non_neg_integer(),
          max_recursion_depth: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          remaining_time_ms: non_neg_integer() | nil,
          cancelled: term() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def reserve_lm(pid, count) when is_integer(count) and count >= 0,
    do: GenServer.call(pid, {:reserve_lm, count})

  def lease_lm(pid, count) when is_integer(count) and count >= 0,
    do: GenServer.call(pid, {:lease_lm, count})

  def commit_lm(pid, lease), do: GenServer.call(pid, {:commit_lm, lease})
  def release_lm(pid, lease), do: GenServer.call(pid, {:release_lm, lease})

  def enter_recursion(pid, parent_depth),
    do: GenServer.call(pid, {:enter_recursion, parent_depth})

  def register_effect(pid, effect_pid), do: GenServer.call(pid, {:register_effect, effect_pid})

  def unregister_effect(pid, effect_pid),
    do: GenServer.call(pid, {:unregister_effect, effect_pid})

  def check(pid), do: GenServer.call(pid, :check)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def cancel(pid, reason \\ :cancelled), do: GenServer.call(pid, {:cancel, reason})

  @doc false
  @spec task_timeout(pid()) :: timeout()
  def task_timeout(pid) do
    case snapshot(pid).remaining_time_ms do
      nil -> :infinity
      0 -> 1
      remaining -> remaining
    end
  end

  @impl true
  def init(opts) do
    started_at = System.monotonic_time(:millisecond)
    max_time_ms = Keyword.get(opts, :max_time_ms)

    {:ok,
     %{
       max_lm_calls: Keyword.fetch!(opts, :max_lm_calls),
       lm_calls: 0,
       leases: %{},
       max_recursion_depth: Keyword.get(opts, :max_recursion_depth, 1),
       max_recursion_depth_reached: 0,
       effects: %{},
       started_at: started_at,
       deadline: if(max_time_ms, do: started_at + max_time_ms),
       cancelled: nil
     }}
  end

  @impl true
  def handle_call({:reserve_lm, count}, _from, state) do
    with :ok <- available(state),
         :ok <- within_lm_budget(state, count) do
      state = %{state | lm_calls: state.lm_calls + count}
      {:reply, {:ok, state.lm_calls}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lease_lm, count}, _from, state) do
    with :ok <- available(state),
         :ok <- within_lm_budget(state, count) do
      lease = make_ref()
      state = %{state | leases: Map.put(state.leases, lease, count)}
      {:reply, {:ok, lease}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_lm, lease}, _from, state) do
    with :ok <- available(state),
         {:ok, remaining} when remaining > 0 <- Map.fetch(state.leases, lease) do
      leases =
        if remaining == 1,
          do: Map.delete(state.leases, lease),
          else: Map.put(state.leases, lease, remaining - 1)

      state = %{state | leases: leases, lm_calls: state.lm_calls + 1}
      {:reply, {:ok, state.lm_calls}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _invalid_lease ->
        {:reply, {:error, :invalid_lm_call_lease}, state}
    end
  end

  def handle_call({:release_lm, lease}, _from, state) do
    {:reply, :ok, %{state | leases: Map.delete(state.leases, lease)}}
  end

  def handle_call({:enter_recursion, parent_depth}, _from, state)
      when is_integer(parent_depth) and parent_depth >= 0 do
    depth = parent_depth + 1

    with :ok <- available(state),
         true <- depth <= state.max_recursion_depth do
      state = %{
        state
        | max_recursion_depth_reached: max(state.max_recursion_depth_reached, depth)
      }

      {:reply, {:ok, depth}, state}
    else
      false ->
        {:reply, {:error, {:rlm_max_recursion_depth, state.max_recursion_depth}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:register_effect, effect_pid}, _from, state) when is_pid(effect_pid) do
    case available(state) do
      :ok ->
        monitor = Process.monitor(effect_pid)
        {:reply, :ok, %{state | effects: Map.put(state.effects, effect_pid, monitor)}}

      {:error, reason} ->
        Process.exit(effect_pid, :kill)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_effect, effect_pid}, _from, state) do
    case Map.pop(state.effects, effect_pid) do
      {nil, _effects} -> :ok
      {monitor, _effects} -> Process.demonitor(monitor, [:flush])
    end

    {:reply, :ok, %{state | effects: Map.delete(state.effects, effect_pid)}}
  end

  def handle_call(:check, _from, state), do: {:reply, available(state), state}
  def handle_call(:snapshot, _from, state), do: {:reply, build_snapshot(state), state}

  def handle_call({:cancel, reason}, _from, state) do
    state = if state.cancelled, do: state, else: %{state | cancelled: reason}
    Enum.each(Map.keys(state.effects), &Process.exit(&1, :kill))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    effects =
      case Map.get(state.effects, pid) do
        ^monitor -> Map.delete(state.effects, pid)
        _other -> state.effects
      end

    {:noreply, %{state | effects: effects}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.effects), &Process.exit(&1, :kill))
    :ok
  end

  defp available(%{cancelled: reason}) when not is_nil(reason),
    do: {:error, {:rlm_cancelled, reason}}

  defp available(%{deadline: nil}), do: :ok

  defp available(%{deadline: deadline}) do
    if System.monotonic_time(:millisecond) <= deadline,
      do: :ok,
      else: {:error, :rlm_time_budget_exceeded}
  end

  defp within_lm_budget(state, count) do
    reserved = state.leases |> Map.values() |> Enum.sum()

    if state.lm_calls + reserved + count <= state.max_lm_calls,
      do: :ok,
      else: {:error, {:rlm_max_llm_calls, state.max_lm_calls}}
  end

  defp build_snapshot(state) do
    now = System.monotonic_time(:millisecond)

    %{
      lm_calls: state.lm_calls,
      reserved_lm_calls: state.leases |> Map.values() |> Enum.sum(),
      max_lm_calls: state.max_lm_calls,
      max_recursion_depth_reached: state.max_recursion_depth_reached,
      max_recursion_depth: state.max_recursion_depth,
      elapsed_ms: max(now - state.started_at, 0),
      remaining_time_ms: if(state.deadline, do: max(state.deadline - now, 0)),
      cancelled: state.cancelled
    }
  end
end
