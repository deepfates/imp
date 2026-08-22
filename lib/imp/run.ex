defmodule Imp.Run do
  @moduledoc """
  An addressable execution of an Imp program with ordered semantic events.

  `Imp.call/2` remains the minimal program boundary. `Imp.Run` is the optional
  runtime boundary for hosts that need to observe a composed program while it
  is running, cancel its in-flight effects, or explicitly authorize validated
  ReActV2/RLM tool effects. Observation and cancellation use the owned run
  context; security decisions are carried explicitly in `Imp.Execution`.
  Events describe Imp execution; they do not contain ACP, MCP, UI, or transport
  concepts.
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
            emit(:run_started, component: program.__struct__)
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
  def cancel(%__MODULE__{} = run, reason \\ :cancelled, timeout \\ 5_000) do
    _ = Control.cancel(run.control, reason)
    _ = Imp.Tasks.cancel(run.task, timeout)
    stop(run)
  end

  @doc "Releases the event/cancellation control process after a run completes."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{control: control}) do
    if Process.alive?(control), do: GenServer.stop(control, :normal)
    :ok
  catch
    :exit, _reason -> :ok
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
    :input,
    :output,
    :reasoning,
    :tool_call_id,
    :tool_name,
    :error,
    metadata: %{}
  ]

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

  alias Imp.Run.Event

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def emit(pid, kind, attrs), do: GenServer.call(pid, {:emit, kind, attrs})
  def register(pid, fun), do: GenServer.call(pid, {:register, fun})
  def unregister(pid, ref), do: GenServer.call(pid, {:unregister, ref})
  def cancel(pid, reason), do: GenServer.call(pid, {:cancel, reason}, 30_000)
  def barrier(pid, receiver, tag), do: GenServer.call(pid, {:barrier, receiver, tag})
  def attach_task(pid, task_pid), do: GenServer.call(pid, {:attach_task, task_pid})

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       sink: Keyword.fetch!(opts, :event_sink),
       sequence: 0,
       cancellables: %{},
       owner: owner,
       owner_monitor: Process.monitor(owner),
       task_pid: nil,
       cancelled: nil
     }}
  end

  @impl true
  def handle_call({:emit, kind, attrs}, _from, state) do
    event =
      %Event{
        run_id: state.id,
        sequence: state.sequence,
        kind: kind,
        component: Map.get(attrs, :component),
        input: redact(Map.get(attrs, :input)),
        output: redact(Map.get(attrs, :output)),
        reasoning: redact(Map.get(attrs, :reasoning)),
        tool_call_id: Map.get(attrs, :tool_call_id),
        tool_name: Map.get(attrs, :tool_name),
        error: redact(Map.get(attrs, :error)),
        metadata: redact(Map.get(attrs, :metadata, %{}))
      }

    safe_sink(state.sink, event)
    {:reply, :ok, %{state | sequence: state.sequence + 1}}
  end

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
    {:reply, :ok, %{state | task_pid: task_pid}}
  end

  def handle_call({:cancel, reason}, _from, %{cancelled: nil} = state) do
    Enum.each(state.cancellables, fn {_ref, fun} -> safe_cancel(fun, reason) end)
    {:reply, :ok, %{state | cancelled: reason, cancellables: %{}}}
  end

  def handle_call({:cancel, _reason}, _from, state), do: {:reply, :ok, state}

  def handle_call({:barrier, receiver, tag}, _from, state) do
    send(receiver, {:imp_run_barrier, tag})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    Enum.each(state.cancellables, fn {_ref, fun} -> safe_cancel(fun, {:owner_down, reason}) end)

    if is_pid(state.task_pid) and Process.alive?(state.task_pid),
      do: Process.exit(state.task_pid, :kill)

    {:stop, :normal, state}
  end

  defp safe_sink(sink, event) do
    _ = sink.(event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
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
