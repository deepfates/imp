defmodule Imp.Tasks.Admission do
  @moduledoc false

  # Leases on places in named pools. Each pool counts its own leases against
  # the limit its caller passes. `reserve!/2` waits in one FIFO queue for a
  # place; `try_reserve/2` answers `{:error, :busy}` when the pool is full.
  # A lease is tied to a process by a monitor, so a holder that dies gives its
  # place back.

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def reserve!(pool, limit) do
    {:ok, token} = GenServer.call(__MODULE__, {:reserve, pool, limit, :wait}, :infinity)
    token
  end

  def try_reserve(pool, limit), do: GenServer.call(__MODULE__, {:reserve, pool, limit, :busy})
  def transfer(token, pid), do: GenServer.call(__MODULE__, {:transfer, token, pid})
  def release(token), do: GenServer.call(__MODULE__, {:release, token})
  def owned_by?(token, pid), do: GenServer.call(__MODULE__, {:owned_by?, token, pid})
  def status(pool), do: GenServer.call(__MODULE__, {:status, pool})

  @impl true
  def init(_opts),
    do: {:ok, %{leases: %{}, counts: %{}, monitors: %{}, waiters: %{}, queue: :queue.new()}}

  @impl true
  def handle_call({:reserve, pool, limit, mode}, {owner, _tag} = from, state) do
    cond do
      active(state, pool) < limit ->
        {token, state} = grant_lease(state, pool, owner)
        {:reply, {:ok, token}, state}

      mode == :busy ->
        {:reply, {:error, :busy}, state}

      true ->
        waiter = make_ref()
        monitor = Process.monitor(owner)
        entry = %{from: from, owner: owner, monitor: monitor, pool: pool, limit: limit}

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
          | leases:
              Map.put(state.leases, token, %{lease | pid: pid, monitor: monitor, phase: :active}),
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

  def handle_call({:owned_by?, token, pid}, _from, state) do
    {:reply, match?(%{pid: ^pid, phase: :active}, Map.get(state.leases, token)), state}
  end

  def handle_call({:status, pool}, _from, state) do
    queued = Enum.count(state.waiters, fn {_waiter, entry} -> entry.pool == pool end)
    {:reply, %{active: active(state, pool), queued: queued}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, {:lease, token}} -> {:noreply, state |> drop_lease(token, false) |> grant_waiters()}
      {:ok, {:waiter, waiter}} -> {:noreply, drop_waiter(state, waiter, false)}
      :error -> {:noreply, state}
    end
  end

  defp active(state, pool), do: Map.get(state.counts, pool, 0)

  defp drop_lease(state, token, demonitor? \\ true) do
    case Map.pop(state.leases, token) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        if demonitor?, do: Process.demonitor(lease.monitor, [:flush])

        counts =
          case active(state, lease.pool) do
            1 -> Map.delete(state.counts, lease.pool)
            n -> Map.put(state.counts, lease.pool, n - 1)
          end

        %{
          state
          | leases: leases,
            counts: counts,
            monitors: Map.delete(state.monitors, lease.monitor)
        }
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

  defp grant_lease(state, pool, owner, monitor \\ nil) do
    token = make_ref()
    monitor = monitor || Process.monitor(owner)
    lease = %{pid: owner, monitor: monitor, phase: :reserved, pool: pool}

    {token,
     %{
       state
       | leases: Map.put(state.leases, token, lease),
         counts: Map.update(state.counts, pool, 1, &(&1 + 1)),
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

          {:ok, entry} ->
            if active(state, entry.pool) < entry.limit do
              state = %{state | waiters: Map.delete(state.waiters, waiter)}
              {token, state} = grant_lease(state, entry.pool, entry.owner, entry.monitor)
              GenServer.reply(entry.from, {:ok, token})
              grant_waiters(state)
            else
              %{state | queue: :queue.in_r(waiter, state.queue)}
            end
        end
    end
  end
end

defmodule Imp.Tasks do
  @moduledoc """
  Tasks that carry the caller's Imp context.

  `async/1` and `async_nolink/1` start a supervised task that runs with the
  settings, `Imp.Run` context and telemetry context of the process that
  started it, so a model call or tool event inside the task belongs to the
  caller's run, and reads the caller's `Imp.configure/1` and `Imp.context/2`
  settings. A plain `Task` does not carry them.

  Every such task takes a place in one machine-wide pool bounded by the
  `:async_max_workers` setting, and waits for a place when the pool is full. A
  host that bounds its own runs passes `admission: {pool, limit}` to
  `Imp.Run.start/3` instead.
  """
  @supervisor Imp.TaskSupervisor
  @unlinked_supervisor Imp.UnlinkedTaskSupervisor
  @admission Imp.Tasks.Admission
  @admission_token_key {__MODULE__, :admission_token}
  # The pool every task joins unless its caller names another.
  @machine_pool {__MODULE__, :machine}

  @async_stream_option_schema [
    max_concurrency: [type: :pos_integer],
    ordered: [type: :boolean],
    timeout: [type: {:or, [:timeout, :pos_integer]}],
    on_timeout: [type: {:in, [:exit, :kill_task]}],
    zip_input_on_exit: [type: :boolean]
  ]

  @doc false
  def supervisor, do: @supervisor

  @doc false
  def unlinked_supervisor, do: @unlinked_supervisor

  @doc false
  def admission_status do
    ensure_runtime!()
    @admission.status(@machine_pool)
  end

  @doc false
  def supervised? do
    Enum.all?([@admission, @supervisor, @unlinked_supervisor], &(Process.whereis(&1) != nil))
  end

  @doc """
  Starts a linked supervised task that carries the caller's settings, run and
  telemetry context.

      iex> task = Imp.context([task_marker: :inside], fn ->
      ...>   Imp.Tasks.async(fn -> Imp.Settings.fetch!(:task_marker) end)
      ...> end)
      iex> Task.await(task)
      :inside

  """
  @spec async((-> term())) :: Task.t()
  def async(fun) when is_function(fun, 0) do
    start_task(@supervisor, :linked, fun)
  end

  def async(fun) do
    raise ArgumentError, "Imp.Tasks.async/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc """
  Starts an unlinked supervised task that carries the caller's settings, run
  and telemetry context. Await it with `Task.yield/2` or `Task.await/2`.
  """
  @spec async_nolink((-> term())) :: Task.t()
  def async_nolink(fun) when is_function(fun, 0) do
    start_task(@unlinked_supervisor, :nolink, fun)
  end

  def async_nolink(fun) do
    raise ArgumentError,
          "Imp.Tasks.async_nolink/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc false
  # An unlinked task admitted to the caller's own pool instead of the machine
  # pool: at most `limit` tasks hold a place in `pool` at once, and a full pool
  # answers `{:error, :busy}` without waiting. Work the task starts in turn
  # joins the machine pool as usual.
  @spec async_nolink_in_pool((-> term()), term(), pos_integer()) ::
          {:ok, Task.t()} | {:error, :busy}
  def async_nolink_in_pool(fun, pool, limit)
      when is_function(fun, 0) and is_integer(limit) and limit > 0 do
    snapshot = Imp.Settings.snapshot()
    ensure_runtime!()

    with {:ok, token} <- @admission.try_reserve({:pool, pool}, limit) do
      {:ok, start_admitted_task(@unlinked_supervisor, :nolink, fun, snapshot, token)}
    end
  end

  @doc false
  def async_nolink_borrowed(fun) when is_function(fun, 0) do
    case current_admission() do
      {token, owner} when owner == self() ->
        ensure_runtime!()

        if @admission.owned_by?(token, owner) do
          start_borrowed_task(token, owner, fun)
        else
          async_nolink(fun)
        end

      _other ->
        async_nolink(fun)
    end
  end

  def async_nolink_borrowed(fun) do
    raise ArgumentError,
          "Imp.Tasks.async_nolink_borrowed/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc false
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

  @doc false
  # Lazily runs a function through Imp's bounded, supervised task boundary.
  # Settings are captured when `async_stream/3` is called. Stream-local fan-out
  # is capped by the effective `:async_max_workers`; concurrent Imp work waits
  # for capacity instead of turning contention into a prediction failure. A
  # stream synchronously enumerated inside an admitted Imp task reuses that
  # task's slot serially, so nested optimizer fan-out remains bounded without
  # self-deadlocking when the limit is one.
  def async_stream(enumerable, fun, opts \\ [])

  def async_stream(enumerable, fun, opts) when is_function(fun, 1) do
    enumerable = validate_enumerable!(enumerable)
    opts = Imp.Options.validate!(opts, @async_stream_option_schema, "Imp.Tasks.async_stream/3")
    snapshot = Imp.Settings.snapshot()
    telemetry_context = Imp.Telemetry.context()
    run_context = Imp.Run.context()
    streaming_context = Imp.Streaming.Execution.context()
    max_workers = Map.fetch!(snapshot, :async_max_workers)
    borrowed = current_admission()
    enumerator = self()
    stream_max_workers = if borrowed, do: 1, else: max_workers

    opts =
      Keyword.update(opts, :max_concurrency, stream_max_workers, &min(&1, stream_max_workers))

    wrapped = fn item ->
      case borrowed do
        {token, lease_owner} ->
          if direct_task_caller?(@supervisor, enumerator) and
               @admission.owned_by?(token, lease_owner) do
            run_borrowed(
              snapshot,
              telemetry_context,
              run_context,
              streaming_context,
              token,
              lease_owner,
              fn ->
                fun.(item)
              end
            )
          else
            run_admitted(
              snapshot,
              telemetry_context,
              run_context,
              streaming_context,
              max_workers,
              fn ->
                fun.(item)
              end
            )
          end

        nil ->
          run_admitted(
            snapshot,
            telemetry_context,
            run_context,
            streaming_context,
            max_workers,
            fn -> fun.(item) end
          )
      end
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
    ensure_runtime!()
    token = @admission.reserve!(@machine_pool, Map.fetch!(snapshot, :async_max_workers))
    start_admitted_task(supervisor, link, fun, snapshot, token)
  end

  defp start_admitted_task(supervisor, link, fun, snapshot, token) do
    telemetry_context = Imp.Telemetry.context()
    run_context = Imp.Run.context()
    streaming_context = Imp.Streaming.Execution.context()
    owner = self()

    wrapped = fn ->
      owner_monitor = Process.monitor(owner)

      receive do
        {:imp_start, ^token} ->
          Process.demonitor(owner_monitor, [:flush])

          try do
            with_admission(token, self(), fn ->
              with_runtime_context(
                snapshot,
                telemetry_context,
                run_context,
                streaming_context,
                fun
              )
            end)
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

  # A demand-driven producer called synchronously from an admitted task is not
  # additional fan-out: its consumer is waiting while the producer owns the
  # next step. Reuse that lease without transferring or releasing it. This is
  # intentionally narrower than making arbitrary nested async work reentrant.
  defp start_borrowed_task(token, owner, fun) do
    snapshot = Imp.Settings.snapshot()
    telemetry_context = Imp.Telemetry.context()
    run_context = Imp.Run.context()
    streaming_context = Imp.Streaming.Execution.context()

    wrapped = fn ->
      with_admission(token, owner, fn ->
        with_runtime_context(snapshot, telemetry_context, run_context, streaming_context, fun)
      end)
    end

    Task.Supervisor.async_nolink(@unlinked_supervisor, wrapped)
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

  defp run_admitted(snapshot, telemetry_context, run_context, streaming_context, max_workers, fun) do
    token = @admission.reserve!(@machine_pool, max_workers)
    :ok = @admission.transfer(token, self())

    try do
      with_admission(token, self(), fn ->
        with_runtime_context(snapshot, telemetry_context, run_context, streaming_context, fun)
      end)
    after
      @admission.release(token)
    end
  end

  defp run_borrowed(
         snapshot,
         telemetry_context,
         run_context,
         streaming_context,
         token,
         owner,
         fun
       ) do
    with_admission(token, owner, fn ->
      with_runtime_context(snapshot, telemetry_context, run_context, streaming_context, fun)
    end)
  end

  defp with_runtime_context(snapshot, telemetry_context, run_context, streaming_context, fun) do
    Imp.Telemetry.with_context(telemetry_context, fn ->
      Imp.Settings.with_snapshot(snapshot, fn ->
        run = fn ->
          if is_pid(run_context), do: Imp.Run.with_context(run_context, fun), else: fun.()
        end

        if is_map(streaming_context),
          do: Imp.Streaming.Execution.with_context(streaming_context, run),
          else: run.()
      end)
    end)
  end

  defp current_admission, do: Process.get(@admission_token_key)

  # Task.Supervisor records the process that directly enumerates async_stream in
  # the child task's standard $callers chain. Only that direct caller may lend
  # its lease. An escaped stream or a stream enumerated by another process goes
  # through ordinary admission instead of bypassing the global bound.
  defp direct_task_caller?(supervisor, owner) do
    Process.get(:"$callers", []) |> List.first() == owner and
      self() in Task.Supervisor.children(supervisor)
  end

  defp with_admission(token, owner, fun) do
    previous = Process.get(@admission_token_key)
    Process.put(@admission_token_key, {token, owner})

    try do
      fun.()
    after
      if previous do
        Process.put(@admission_token_key, previous)
      else
        Process.delete(@admission_token_key)
      end
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
