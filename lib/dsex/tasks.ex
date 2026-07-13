defmodule DSEx.Tasks.OverloadedError do
  @moduledoc "Raised when a DSEx task cannot acquire async worker capacity."

  defexception [:max_workers, :active]

  @impl true
  def message(%__MODULE__{max_workers: max_workers, active: active}) do
    "DSEx async capacity is exhausted (#{active}/#{max_workers} workers active)"
  end
end

defmodule DSEx.Tasks.Admission do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def reserve!(max_workers) do
    case GenServer.call(__MODULE__, {:reserve, max_workers}) do
      {:ok, token} ->
        token

      {:error, active} ->
        raise DSEx.Tasks.OverloadedError, max_workers: max_workers, active: active
    end
  end

  def transfer(token, pid), do: GenServer.call(__MODULE__, {:transfer, token, pid})
  def release(token), do: GenServer.call(__MODULE__, {:release, token})
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts), do: {:ok, %{leases: %{}, monitors: %{}}}

  @impl true
  def handle_call({:reserve, max_workers}, {owner, _tag}, state) do
    active = map_size(state.leases)

    if active < max_workers do
      token = make_ref()
      monitor = Process.monitor(owner)
      lease = %{pid: owner, monitor: monitor, phase: :reserved}

      {:reply, {:ok, token},
       %{
         state
         | leases: Map.put(state.leases, token, lease),
           monitors: Map.put(state.monitors, monitor, token)
       }}
    else
      {:reply, {:error, active}, state}
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
              state.monitors
              |> Map.delete(lease.monitor)
              |> Map.put(monitor, token)
        }

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :unknown_lease}, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, drop_lease(state, token)}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{active: map_size(state.leases), queued: 0}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, token} -> {:noreply, drop_lease(state, token, false)}
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
end

defmodule DSEx.Tasks do
  @moduledoc """
  Supervised, bounded task boundary for DSEx runtime fan-out.

  DSEx rejects standalone submissions immediately when the effective
  `:async_max_workers` capacity is exhausted. No pending work queue is kept.
  """

  @supervisor DSEx.TaskSupervisor
  @unlinked_supervisor DSEx.UnlinkedTaskSupervisor
  @admission DSEx.Tasks.Admission

  @async_stream_option_schema [
    max_concurrency: [type: :pos_integer],
    ordered: [type: :boolean],
    timeout: [type: {:or, [:timeout, :pos_integer]}],
    on_timeout: [type: {:in, [:exit, :kill_task]}],
    zip_input_on_exit: [type: :boolean]
  ]

  @doc "Returns the linked task supervisor name used by DSEx async helpers."
  def supervisor, do: @supervisor

  @doc "Returns the unlinked task supervisor name used by DSEx fire-and-observe helpers."
  def unlinked_supervisor, do: @unlinked_supervisor

  @doc false
  def admission_status do
    ensure_runtime!()
    @admission.status()
  end

  @doc "Returns whether the DSEx admission boundary and both task supervisors are running."
  def supervised? do
    Enum.all?([@admission, @supervisor, @unlinked_supervisor], &(Process.whereis(&1) != nil))
  end

  @doc """
  Starts a linked supervised task with a submission-time settings snapshot.

      iex> task = DSEx.context([task_marker: :inside], fn ->
      ...>   DSEx.Tasks.async(fn -> DSEx.Settings.fetch!(:task_marker) end)
      ...> end)
      iex> Task.await(task)
      :inside

  """
  def async(fun) when is_function(fun, 0) do
    start_task(@supervisor, :linked, fun)
  end

  def async(fun) do
    raise ArgumentError, "DSEx.Tasks.async/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc "Starts an unlinked supervised task with a submission-time settings snapshot."
  def async_nolink(fun) when is_function(fun, 0) do
    start_task(@unlinked_supervisor, :nolink, fun)
  end

  def async_nolink(fun) do
    raise ArgumentError,
          "DSEx.Tasks.async_nolink/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc "Cancels a supervised task and waits up to `timeout` milliseconds for termination."
  def cancel(task, timeout \\ 5_000)

  def cancel(%Task{} = task, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    Task.shutdown(task, timeout)
  end

  def cancel(%Task{}, timeout) do
    raise ArgumentError,
          "DSEx.Tasks.cancel/2 expects :infinity or a positive timeout, got: #{inspect(timeout)}"
  end

  def cancel(task, _timeout) do
    raise ArgumentError, "DSEx.Tasks.cancel/2 expects a Task struct, got: #{inspect(task)}"
  end

  @doc """
  Lazily runs a function through DSEx's bounded, supervised task boundary.

  Settings are captured when `async_stream/3` is called. Stream-local fan-out
  is capped by the effective `:async_max_workers`; concurrent DSEx work can
  still cause individual stream items to exit with `DSEx.Tasks.OverloadedError`.
  """
  def async_stream(enumerable, fun, opts \\ [])

  def async_stream(enumerable, fun, opts) when is_function(fun, 1) do
    enumerable = validate_enumerable!(enumerable)
    opts = DSEx.Options.validate!(opts, @async_stream_option_schema, "DSEx.Tasks.async_stream/3")
    snapshot = DSEx.Settings.snapshot()
    max_workers = Map.fetch!(snapshot, :async_max_workers)
    opts = Keyword.update(opts, :max_concurrency, max_workers, &min(&1, max_workers))

    wrapped = fn item ->
      run_admitted(snapshot, max_workers, fn -> fun.(item) end)
    end

    ensure_runtime!()
    Task.Supervisor.async_stream_nolink(@supervisor, enumerable, wrapped, opts)
  end

  def async_stream(_enumerable, fun, _opts) do
    raise ArgumentError,
          "DSEx.Tasks.async_stream/3 expects an arity-1 function, got: #{inspect(fun)}"
  end

  defp start_task(supervisor, link, fun) do
    snapshot = DSEx.Settings.snapshot()
    max_workers = Map.fetch!(snapshot, :async_max_workers)
    ensure_runtime!()
    token = @admission.reserve!(max_workers)
    owner = self()

    wrapped = fn ->
      owner_monitor = Process.monitor(owner)

      receive do
        {:dsex_start, ^token} ->
          Process.demonitor(owner_monitor, [:flush])

          try do
            DSEx.Settings.with_snapshot(snapshot, fun)
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
        send(task.pid, {:dsex_start, token})
        task

      {:error, reason} ->
        Task.shutdown(task, :brutal_kill)
        @admission.release(token)
        raise "failed to transfer DSEx async admission lease: #{inspect(reason)}"
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
      DSEx.Settings.with_snapshot(snapshot, fun)
    after
      @admission.release(token)
    end
  end

  defp validate_enumerable!(enumerable) do
    if Enumerable.impl_for(enumerable) do
      enumerable
    else
      raise ArgumentError,
            "DSEx.Tasks.async_stream/3 expects enumerable input, got: #{inspect(enumerable)}"
    end
  end

  defp ensure_runtime! do
    if Enum.any?([@admission, @supervisor, @unlinked_supervisor], &(Process.whereis(&1) == nil)) do
      case Application.ensure_all_started(:dsex) do
        {:ok, _apps} ->
          :ok

        {:error, reason} ->
          raise "failed to start :dsex application for DSEx.Tasks: #{inspect(reason)}"
      end
    end

    :ok
  end
end
