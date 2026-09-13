defmodule Imp.Run do
  @moduledoc """
  An addressable execution of an Imp program with ordered semantic events.

  `Imp.call/2` remains the minimal program boundary. `Imp.Run` is the optional
  runtime boundary for hosts that need to observe a composed program while it
  is running, cancel its in-flight effects, or explicitly authorize validated
  ReActV2/RLM tool effects. Observation and cancellation use the owned run
  context; security decisions are carried explicitly in `Imp.Execution`.
  Events describe Imp execution; they do not contain ACP, MCP, UI, or transport
  concepts. One run-owned delivery process invokes the event sink serially, so
  a slow observer preserves event order without delaying cancellation or owner
  cleanup. Sinks should still hand work off promptly: a permanently blocked
  sink prevents its own later events and barriers from being delivered.

  `events/1` reads the retained native sequence independently of sink progress.
  `cancel_with_events/3` snapshots it before cleanup, including one owner-recorded
  cancellation outcome. This is in-memory evidence, not a durable effects log:
  node/owner death can lose it, and cancellation says nothing about whether an
  unfinished remote write landed. Persist authorization before dispatch when
  that guarantee is needed. `Imp.Run.Event.to_map/1` serializes redacted events.
  Model request/response observations cover `Imp.LM.request/2`; ReActV2 and RLM
  provide their semantic tool call/result events.
  """

  alias Imp.Run.Control

  @context_key :imp_run_control

  @enforce_keys [:task, :control, :id]
  defstruct [:task, :control, :id]

  @type t :: %__MODULE__{task: Task.t(), control: pid(), id: String.t()}

  @doc "Starts an unlinked supervised program run owned by the calling process."
  @spec start(struct(), map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(program, inputs, opts \\ []) when is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    authorize = Keyword.get(opts, :authorize)
    authorization_timeout = Keyword.get(opts, :authorization_timeout, 30_000)

    unless is_function(event_sink, 1) do
      raise ArgumentError, ":event_sink must be an arity-1 function"
    end

    id = Keyword.get_lazy(opts, :id, &new_id/0)
    owner = self()

    execution =
      Imp.Execution.new(
        run_id: id,
        authorize: authorize,
        authorization_timeout: authorization_timeout,
        decision_owner: owner
      )

    with {:ok, control} <- Control.start(owner: self(), id: id, event_sink: event_sink) do
      task =
        Imp.Tasks.async_nolink(fn ->
          with_context(control, fn ->
            emit(:run_started, component: program.__struct__, input: inputs)
            result = Imp.Module.execute(program, inputs, execution)

            case result do
              {:ok, %Imp.Prediction{} = prediction} -> emit(:run_finished, output: prediction)
              {:error, {:execution_cancelled, reason}} -> emit(:run_cancelled, error: reason)
              {:error, reason} -> emit(:run_failed, error: reason)
              other -> emit(:run_failed, error: {:invalid_result, other})
            end

            result
          end)
        end)

      :ok = Control.attach_task(control, task.pid)

      {:ok, %__MODULE__{task: task, control: control, id: id}}
    end
  end

  @doc "Cancels registered effects before terminating the outer supervised task."
  @spec cancel(t(), term(), timeout()) :: :ok
  def cancel(run, reason \\ :cancelled, timeout \\ 5_000)

  def cancel(%__MODULE__{} = run, reason, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    {:ok, _events} = cancel_with_events(run, reason, timeout)
    :ok
  end

  def cancel(%__MODULE__{}, _reason, timeout) do
    raise ArgumentError,
          "Imp.Run.cancel/3 expects :infinity or a positive timeout, got: #{inspect(timeout)}"
  end

  @doc "Returns the ordered redacted events retained by a running or completed run before stop."
  def events(%__MODULE__{control: control}), do: Control.events(control)

  @doc """
  Cancels a run and returns its terminal event snapshot before releasing control.

  This snapshot remains available even when an asynchronous event sink blocks.
  Cancellation does not imply an unfinished external write did not happen.
  """
  def cancel_with_events(run, reason \\ :cancelled, timeout \\ 5_000)

  def cancel_with_events(%__MODULE__{} = run, reason, timeout)
      when timeout == :infinity or (is_integer(timeout) and timeout > 0) do
    :ok = Control.cancel(run.control, reason)
    terminate_task(run.task.pid, timeout)
    events = Control.events(run.control)
    Control.force_stop(run.control)
    {:ok, events}
  end

  @doc "Releases the event/cancellation control process after a run completes."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{control: control}) do
    Control.stop(control)
  end

  @doc false
  def barrier(%__MODULE__{control: control}, receiver, tag) when is_pid(receiver) do
    Control.barrier(control, receiver, tag)
  end

  @doc "Emits one ordered, redacted event when called inside an `Imp.Run`."
  @spec emit(atom(), keyword() | map()) :: :ok
  def emit(kind, attrs \\ []) when is_atom(kind) and (is_list(attrs) or is_map(attrs)) do
    case context() do
      control when is_pid(control) -> Control.emit(control, kind, Map.new(attrs))
      nil -> :ok
    end
  end

  @doc false
  def register_cancellable(fun) when is_function(fun, 1) do
    case context() do
      control when is_pid(control) -> Control.register(control, fun)
      nil -> nil
    end
  end

  @doc false
  def unregister_cancellable(nil), do: :ok

  def unregister_cancellable(ref) when is_reference(ref) do
    case context() do
      control when is_pid(control) -> Control.unregister(control, ref)
      nil -> :ok
    end
  end

  @doc false
  def context, do: Process.get(@context_key)

  @doc false
  def with_context(control, fun) when is_pid(control) and is_function(fun, 0) do
    previous = Process.get(@context_key, :unset)
    Process.put(@context_key, control)

    try do
      fun.()
    after
      case previous do
        :unset -> Process.delete(@context_key)
        value -> Process.put(@context_key, value)
      end
    end
  end

  @doc false
  def new_event_id(prefix \\ "event") when is_binary(prefix) do
    prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp terminate_task(pid, timeout) do
    monitor = Process.monitor(pid)

    if Process.alive?(pid), do: Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end
    end
  end

  defp new_id, do: new_event_id("run")
end

defmodule Imp.Run.Event do
  @moduledoc "A single ordered, protocol-neutral execution event."

  @enforce_keys [:run_id, :sequence, :kind]
  defstruct [
    :run_id,
    :sequence,
    :kind,
    :component,
    :timestamp,
    :input,
    :output,
    :reasoning,
    :tool_call_id,
    :tool_name,
    :error,
    metadata: %{}
  ]

  @doc "Serializes a native event for JSON storage, redacting again at the boundary."
  def to_map(%__MODULE__{} = event) do
    event |> Imp.Redaction.redact() |> Imp.Observability.Inspection.json_safe()
  end

  @type t :: %__MODULE__{
          run_id: String.t(),
          sequence: non_neg_integer(),
          kind: atom(),
          component: module() | atom() | String.t() | nil,
          input: term(),
          output: term(),
          reasoning: term(),
          tool_call_id: String.t() | nil,
          tool_name: atom() | String.t() | nil,
          error: term(),
          metadata: map()
        }
end

defmodule Imp.Run.Control do
  @moduledoc false

  use GenServer

  alias Imp.Run.{Event, EventDelivery}

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def events(pid), do: GenServer.call(pid, :events)
  def emit(pid, kind, attrs), do: GenServer.call(pid, {:emit, kind, attrs})
  def register(pid, fun), do: GenServer.call(pid, {:register, fun})
  def unregister(pid, ref), do: GenServer.call(pid, {:unregister, ref})
  def cancel(pid, reason), do: GenServer.call(pid, {:cancel, reason}, 30_000)
  def barrier(pid, receiver, tag), do: GenServer.call(pid, {:barrier, receiver, tag})
  def attach_task(pid, task_pid), do: GenServer.call(pid, {:attach_task, task_pid})

  def stop(pid) do
    if Process.alive?(pid) do
      delivery = GenServer.call(pid, :delivery)

      try do
        EventDelivery.drain(delivery, 5_000)
      catch
        :exit, _reason -> :ok
      end

      force_stop(pid)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  def force_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    {:ok, delivery} = EventDelivery.start_link(Keyword.fetch!(opts, :event_sink))

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       delivery: delivery,
       sequence: 0,
       events: [],
       terminal: nil,
       task_monitor: nil,
       cancellables: %{},
       owner: owner,
       owner_monitor: Process.monitor(owner),
       task_pid: nil,
       cancelled: nil
     }}
  end

  @impl true
  def handle_call({:emit, kind, attrs}, _from, state) do
    {:reply, :ok, record(state, kind, attrs)}
  end

  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}

  def handle_call(:delivery, _from, state), do: {:reply, state.delivery, state}

  def handle_call({:register, fun}, _from, %{cancelled: nil} = state) do
    ref = make_ref()
    {:reply, ref, %{state | cancellables: Map.put(state.cancellables, ref, fun)}}
  end

  def handle_call({:register, fun}, _from, state) do
    safe_cancel(fun, state.cancelled)
    {:reply, nil, state}
  end

  def handle_call({:unregister, ref}, _from, state) do
    {:reply, :ok, %{state | cancellables: Map.delete(state.cancellables, ref)}}
  end

  def handle_call({:attach_task, task_pid}, _from, state) when is_pid(task_pid) do
    {:reply, :ok, %{state | task_pid: task_pid, task_monitor: Process.monitor(task_pid)}}
  end

  def handle_call({:cancel, reason}, _from, %{cancelled: nil} = state) do
    Enum.each(state.cancellables, fn {_ref, fun} -> safe_cancel(fun, reason) end)

    state =
      record(state, :run_cancelled, %{error: reason, metadata: %{unfinished_effects: :unknown}})

    {:reply, :ok, %{state | cancelled: reason, cancellables: %{}}}
  end

  def handle_call({:cancel, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call({:barrier, receiver, tag}, _from, state) do
    EventDelivery.barrier(state.delivery, receiver, tag)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _task, reason}, %{task_monitor: monitor} = state) do
    # A killed task cannot emit its own terminal event. The run owner can.
    {:noreply,
     record(state, :run_failed, %{
       error: {:task_exit, reason},
       metadata: %{unfinished_effects: :unknown}
     })}
  end

  def handle_info({:DOWN, monitor, :process, owner, reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    Enum.each(state.cancellables, fn {_ref, fun} -> safe_cancel(fun, {:owner_down, reason}) end)

    if is_pid(state.task_pid) and Process.alive?(state.task_pid),
      do: Process.exit(state.task_pid, :kill)

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.delivery) do
      Process.unlink(state.delivery)
      Process.exit(state.delivery, :kill)
    end

    :ok
  end

  defp record(%{terminal: terminal} = state, _kind, _attrs) when not is_nil(terminal), do: state

  defp record(state, kind, attrs) do
    event = %Event{
      run_id: state.id,
      sequence: state.sequence,
      kind: kind,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      component: Map.get(attrs, :component),
      input: redact(Map.get(attrs, :input)),
      output: redact(Map.get(attrs, :output)),
      reasoning: redact(Map.get(attrs, :reasoning)),
      tool_call_id: Map.get(attrs, :tool_call_id),
      tool_name: Map.get(attrs, :tool_name),
      error: redact(Map.get(attrs, :error)),
      metadata: redact(Map.get(attrs, :metadata, %{}))
    }

    EventDelivery.deliver(state.delivery, event)
    terminal = if kind in [:run_finished, :run_failed, :run_cancelled], do: kind, else: nil
    %{state | sequence: state.sequence + 1, events: [event | state.events], terminal: terminal}
  end

  defp safe_cancel(fun, reason) do
    _ = fun.(reason)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp redact(nil), do: nil
  defp redact(value), do: Imp.Redaction.redact(value)
end

defmodule Imp.Run.EventDelivery do
  @moduledoc false

  use GenServer

  def start_link(sink), do: GenServer.start_link(__MODULE__, sink)
  def deliver(pid, event), do: GenServer.cast(pid, {:deliver, event})
  def barrier(pid, receiver, tag), do: GenServer.cast(pid, {:barrier, receiver, tag})
  def drain(pid, timeout), do: GenServer.call(pid, :drain, timeout)

  @impl true
  def init(sink), do: {:ok, sink}

  @impl true
  def handle_cast({:deliver, event}, sink) do
    safe_sink(sink, event)
    {:noreply, sink}
  end

  def handle_cast({:barrier, receiver, tag}, sink) do
    send(receiver, {:imp_run_barrier, tag})
    {:noreply, sink}
  end

  @impl true
  def handle_call(:drain, _from, sink), do: {:reply, :ok, sink}

  defp safe_sink(sink, event) do
    _ = sink.(event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
