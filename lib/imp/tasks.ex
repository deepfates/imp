defmodule Imp.Tasks.Admission do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def reserve!(max_workers) do
    {:ok, token} = GenServer.call(__MODULE__, {:reserve, max_workers}, :infinity)
    token
  end

  def transfer(token, pid), do: GenServer.call(__MODULE__, {:transfer, token, pid})
  def release(token), do: GenServer.call(__MODULE__, {:release, token})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts),
    do: {:ok, %{leases: %{}, monitors: %{}, waiters: %{}, queue: :queue.new()}}

  @impl true
  def handle_call({:reserve, max_workers}, {owner, _tag} = from, state) do
    active = map_size(state.leases)

    if active < max_workers do
      {token, state} = grant_lease(state, owner)
      {:reply, {:ok, token}, state}
    else
      waiter = make_ref()
      monitor = Process.monitor(owner)
      entry = %{from: from, owner: owner, monitor: monitor, max_workers: max_workers}

      {:noreply,
       %{
         state
         | waiters: Map.put(state.waiters, waiter, entry),
           queue: :queue.in(waiter, state.queue),
           monitors: Map.put(state.monitors, monitor, {:waiter, waiter})
       }}
    end
  end

  def handle_call({:transfer, token, pid}, _from, state) do
    case Map.fetch(state.leases, token) do
      {:ok, %{pid: ^pid} = lease} ->
        {:reply, :ok, put_in(state, [:leases, token], %{lease | phase: :active})}

      {:ok, lease} ->
        Process.demonitor(lease.monitor, [:flush])
        monitor = Process.monitor(pid)

        state = %{
          state
          | leases: Map.put(state.leases, token, %{pid: pid, monitor: monitor, phase: :active}),
            monitors:
              state.monitors |> Map.delete(lease.monitor) |> Map.put(monitor, {:lease, token})
        }

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_lease}, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, state |> drop_lease(token) |> grant_waiters()}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: map_size(state.leases), queued: map_size(state.waiters)}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, {:lease, token}} -> {:noreply, state |> drop_lease(token, false) |> grant_waiters()}
      {:ok, {:waiter, waiter}} -> {:noreply, drop_waiter(state, waiter, false)}
      :error -> {:noreply, state}
    end
  end

  defp drop_lease(state, token, demonitor? \\ true) do
    case Map.pop(state.leases, token) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        if demonitor?, do: Process.demonitor(lease.monitor, [:flush])
        %{state | leases: leases, monitors: Map.delete(state.monitors, lease.monitor)}
    end
  end

  defp drop_waiter(state, waiter, demonitor?) do
    case Map.pop(state.waiters, waiter) do
      {nil, _waiters} ->
        state

      {entry, waiters} ->
        if demonitor?, do: Process.demonitor(entry.monitor, [:flush])
        %{state | waiters: waiters, monitors: Map.delete(state.monitors, entry.monitor)}
    end
  end

  defp grant_lease(state, owner, monitor \\ nil) do
    token = make_ref()
    monitor = monitor || Process.monitor(owner)
    lease = %{pid: owner, monitor: monitor, phase: :reserved}

    {token,
     %{
       state
       | leases: Map.put(state.leases, token, lease),
         monitors: Map.put(state.monitors, monitor, {:lease, token})
     }}
  end

  defp grant_waiters(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, waiter}, queue} ->
        state = %{state | queue: queue}

        case Map.fetch(state.waiters, waiter) do
          :error ->
            grant_waiters(state)

          {:ok, entry} when map_size(state.leases) < entry.max_workers ->
            state = %{state | waiters: Map.delete(state.waiters, waiter)}
            {token, state} = grant_lease(state, entry.owner, entry.monitor)
            GenServer.reply(entry.from, {:ok, token})
            grant_waiters(state)

          {:ok, _entry} ->
            %{state | queue: :queue.in_r(waiter, state.queue)}
        end
    end
  end
end

defmodule Imp.Tasks do
  @moduledoc """
  Supervised, bounded task boundary for Imp runtime fan-out.

  Imp applies monitored FIFO backpressure when the effective
  `:async_max_workers` capacity is exhausted.
  """

  @supervisor Imp.TaskSupervisor
  @unlinked_supervisor Imp.UnlinkedTaskSupervisor
  @admission Imp.Tasks.Admission

  @async_stream_option_schema [
    max_concurrency: [type: :pos_integer],
    ordered: [type: :boolean],
    timeout: [type: {:or, [:timeout, :pos_integer]}],
    on_timeout: [type: {:in, [:exit, :kill_task]}],
    zip_input_on_exit: [type: :boolean]
  ]

  @doc "Returns the linked task supervisor name used by Imp async helpers."
  def supervisor, do: @supervisor

  @doc "Returns the unlinked task supervisor name used by Imp fire-and-observe helpers."
  def unlinked_supervisor, do: @unlinked_supervisor

  @doc false
  def admission_status do
    ensure_runtime!()
    @admission.status()
  end

  @doc "Returns whether the Imp admission boundary and both task supervisors are running."
  def supervised? do
    Enum.all?([@admission, @supervisor, @unlinked_supervisor], &(Process.whereis(&1) != nil))
  end

  @doc """
  Starts a linked supervised task with a submission-time settings snapshot.

      iex> task = Imp.context([task_marker: :inside], fn ->
      ...>   Imp.Tasks.async(fn -> Imp.Settings.fetch!(:task_marker) end)
      ...> end)
      iex> Task.await(task)
      :inside

  """
  def async(fun) when is_function(fun, 0) do
    start_task(@supervisor, :linked, fun)
  end

  def async(fun) do
    raise ArgumentError, "Imp.Tasks.async/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc "Starts an unlinked supervised task with a submission-time settings snapshot."
  def async_nolink(fun) when is_function(fun, 0) do
    start_task(@unlinked_supervisor, :nolink, fun)
  end

  def async_nolink(fun) do
    raise ArgumentError,
          "Imp.Tasks.async_nolink/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc "Cancels a supervised task and waits up to `timeout` milliseconds for termination."
  def cancel(task, timeout \\ 5_000)

  def cancel(%Task{} = task, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    Task.shutdown(task, timeout)
  end

  def cancel(%Task{}, timeout) do
    raise ArgumentError,
          "Imp.Tasks.cancel/2 expects :infinity or a positive timeout, got: #{inspect(timeout)}"
  end

  def cancel(task, _timeout) do
    raise ArgumentError, "Imp.Tasks.cancel/2 expects a Task struct, got: #{inspect(task)}"
  end

  @doc """
  Lazily runs a function through Imp's bounded, supervised task boundary.

  Settings are captured when `async_stream/3` is called. Stream-local fan-out
  is capped by the effective `:async_max_workers`; concurrent Imp work waits
  for capacity instead of turning contention into a prediction failure.
  """
  def async_stream(enumerable, fun, opts \\ [])

  def async_stream(enumerable, fun, opts) when is_function(fun, 1) do
    enumerable = validate_enumerable!(enumerable)
    opts = Imp.Options.validate!(opts, @async_stream_option_schema, "Imp.Tasks.async_stream/3")
    snapshot = Imp.Settings.snapshot()
    max_workers = Map.fetch!(snapshot, :async_max_workers)
    opts = Keyword.update(opts, :max_concurrency, max_workers, &min(&1, max_workers))

    wrapped = fn item ->
      run_admitted(snapshot, max_workers, fn -> fun.(item) end)
    end

    ensure_runtime!()
    Task.Supervisor.async_stream(@supervisor, enumerable, wrapped, opts)
  end

  def async_stream(_enumerable, fun, _opts) do
    raise ArgumentError,
          "Imp.Tasks.async_stream/3 expects an arity-1 function, got: #{inspect(fun)}"
  end

  defp start_task(supervisor, link, fun) do
    snapshot = Imp.Settings.snapshot()
    max_workers = Map.fetch!(snapshot, :async_max_workers)
    ensure_runtime!()
    token = @admission.reserve!(max_workers)
    owner = self()

    wrapped = fn ->
      owner_monitor = Process.monitor(owner)

      receive do
        {:imp_start, ^token} ->
          Process.demonitor(owner_monitor, [:flush])

          try do
            Imp.Settings.with_snapshot(snapshot, fun)
          after
            @admission.release(token)
          end

        {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
          exit(:shutdown)
      end
    end

    task = spawn_task(supervisor, link, wrapped, token)

    case @admission.transfer(token, task.pid) do
      :ok ->
        send(task.pid, {:imp_start, token})
        task

      {:error, reason} ->
        Task.shutdown(task, :brutal_kill)
        @admission.release(token)
        raise "failed to transfer Imp async admission lease: #{inspect(reason)}"
    end
  end

  defp spawn_task(supervisor, link, wrapped, token) do
    try do
      case link do
        :linked -> Task.Supervisor.async(supervisor, wrapped)
        :nolink -> Task.Supervisor.async_nolink(supervisor, wrapped)
      end
    catch
      kind, reason ->
        @admission.release(token)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp run_admitted(snapshot, max_workers, fun) do
    token = @admission.reserve!(max_workers)
    :ok = @admission.transfer(token, self())

    try do
      Imp.Settings.with_snapshot(snapshot, fun)
    after
      @admission.release(token)
    end
  end

  defp validate_enumerable!(enumerable) do
    if Enumerable.impl_for(enumerable) do
      enumerable
    else
      raise ArgumentError,
            "Imp.Tasks.async_stream/3 expects enumerable input, got: #{inspect(enumerable)}"
    end
  end

  defp ensure_runtime! do
    if Enum.any?([@admission, @supervisor, @unlinked_supervisor], &(Process.whereis(&1) == nil)) do
      case Application.ensure_all_started(:imp) do
        {:ok, _apps} ->
          :ok

        {:error, reason} ->
          raise "failed to start :imp application for Imp.Tasks: #{inspect(reason)}"
      end
    end

    :ok
  end
end
