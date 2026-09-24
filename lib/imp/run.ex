defmodule Imp.Run do
  @moduledoc """
  An addressable execution of an Imp program with ordered semantic events.

  `Imp.call/2` is the minimal program boundary. `Imp.Run` is the optional
  runtime boundary for hosts that need to observe a composed program while it
  is running, cancel its in-flight effects, or explicitly authorize validated
  ReActV2 and RLM tool effects. Observation and cancellation use the owned run
  context; authorization decisions are carried explicitly in `Imp.Execution`.
  Events describe Imp execution only: they contain no ACP, MCP, UI or transport
  concepts. One run-owned delivery process invokes the event sink serially, so
  a slow observer preserves event order without delaying cancellation or owner
  cleanup. A sink should still hand work off promptly, because a blocked sink
  holds up its own later events and barriers.

  `events/1` reads the retained native sequence independently of sink progress.
  `cancel_with_events/3` snapshots that sequence before cleanup, including one
  owner-recorded cancellation outcome. The snapshot is in-memory evidence, not a
  durable effects log: node or owner death loses it, and cancellation says
  nothing about whether an unfinished remote write landed. Persist authorization
  before dispatch when that guarantee is needed. `Imp.Run.Event.to_map/1`
  serializes a redacted event. Model request and response observations cover
  `Imp.LM.request/2`; ReActV2 and RLM emit the semantic tool call and result
  events, and each `:tool_result` carries `metadata.outcome`, the call's
  `Imp.Tool.outcome/1`.

  A `:model_request` carries the messages as its input and the rest of the
  request as metadata: `:options`, the request options with the tool
  definitions removed, and `:tools_hash`, a SHA-256 of those definitions (or
  `nil` when the request offered none). The definitions themselves are emitted
  once per distinct hash per run, as a `:tools_offered` event whose input is the
  tool list as sent, so a run's record holds every request whole without
  repeating a roster that does not change.

  Capture defaults to 64 KiB per event and a 512-event, 4 MiB snapshot;
  `:max_event_bytes`, `:max_events` and `:max_snapshot_bytes` override them at
  start. Each takes a positive integer or `:infinity`, which removes that bound
  entirely: with `:max_event_bytes` set to `:infinity` an event reaches the sink
  and the snapshot whole however large it is, and with `:max_events` and
  `:max_snapshot_bytes` set to `:infinity` nothing is ever evicted. A host that
  must keep a complete record of a run sets all three. An oversized event
  payload becomes a digest and size marker before sink delivery. A failed
  event keeps a small error marker in its place, with the validated HTTP
  status, provider code and retryability when present and when the marker fits,
  never the error message or the request and response bodies. Snapshot
  eviction adds a `:capture_gap` marker. A sink receives every bounded event;
  the snapshot is a bounded recent window.
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

    with {:ok, control} <-
           Control.start(
             owner: self(),
             id: id,
             event_sink: event_sink,
             capture: Keyword.take(opts, [:max_events, :max_event_bytes, :max_snapshot_bytes])
           ) do
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
  # Per-run "have I already recorded this?" state, so an observation that only
  # has to be made once per run is made once. Returns true the first time the
  # run sees `key` and false afterwards; outside a run there is nothing to
  # record against, so it is always false.
  def first_seen?(key) do
    case context() do
      control when is_pid(control) -> Control.first_seen?(control, key)
      nil -> false
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
          timestamp: String.t() | nil,
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
  def first_seen?(pid, key), do: GenServer.call(pid, {:first_seen, key})
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
    capture = Keyword.get(opts, :capture, [])

    limits = %{
      max_events: Keyword.get(capture, :max_events, 512),
      max_event_bytes: Keyword.get(capture, :max_event_bytes, 65_536),
      max_snapshot_bytes: Keyword.get(capture, :max_snapshot_bytes, 4_194_304)
    }

    unless Enum.all?(limits, fn {_, n} -> bound?(n) end),
      do: raise(ArgumentError, "run capture limits must be positive integers or :infinity")

    {:ok, delivery} = EventDelivery.start_link(Keyword.fetch!(opts, :event_sink))

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       delivery: delivery,
       sequence: 0,
       events: [],
       dropped_events: 0,
       snapshot_bytes: 0,
       limits: limits,
       terminal: nil,
       task_monitor: nil,
       cancellables: %{},
       owner: owner,
       owner_monitor: Process.monitor(owner),
       task_pid: nil,
       cancelled: nil,
       seen: MapSet.new()
     }}
  end

  @impl true
  def handle_call({:emit, kind, attrs}, _from, state) do
    {:reply, :ok, record(state, kind, attrs)}
  end

  def handle_call(:events, _from, state) do
    events = Enum.reverse(state.events)

    events =
      if state.dropped_events > 0 do
        first_sequence =
          case events do
            [first | _] -> first.sequence
            [] -> state.sequence
          end

        [
          %Event{
            run_id: state.id,
            sequence: first_sequence - 1,
            kind: :capture_gap,
            metadata: %{dropped_events: state.dropped_events, reason: :snapshot_capacity}
          }
          | events
        ]
      else
        events
      end

    {:reply, events, state}
  end

  def handle_call(:delivery, _from, state), do: {:reply, state.delivery, state}

  def handle_call({:first_seen, key}, _from, state) do
    if MapSet.member?(state.seen, key) do
      {:reply, false, state}
    else
      {:reply, true, %{state | seen: MapSet.put(state.seen, key)}}
    end
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

    event = bound_event(event, state.limits.max_event_bytes)
    EventDelivery.deliver(state.delivery, event)
    terminal = if kind in [:run_finished, :run_failed, :run_cancelled], do: kind, else: nil

    %{
      state
      | sequence: state.sequence + 1,
        events: [event | state.events],
        terminal: terminal,
        snapshot_bytes: state.snapshot_bytes + :erlang.external_size(event)
    }
    |> bound_snapshot()
  end

  defp bound?(:infinity), do: true
  defp bound?(n), do: is_integer(n) and n > 0

  # `:infinity` is the absence of a bound, not a very large one: the event is
  # never measured, so a host that wants the whole record pays no digest cost.
  defp bound_event(event, :infinity), do: event

  defp bound_event(event, max_bytes) do
    bytes = :erlang.external_size(event)

    if bytes <= max_bytes do
      event
    else
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(event)) |> Base.encode16(case: :lower)

      %{
        event
        | input: nil,
          output: nil,
          reasoning: nil,
          error: bounded_error(event.error),
          metadata:
            event.metadata
            |> Map.take([:model_call_id, :outcome])
            |> Map.put(:capture, %{truncated: true, original_bytes: bytes, sha256: digest})
      }
      |> fit_error_summary(max_bytes)
    end
  end

  defp fit_error_summary(%{error: nil} = event, _max_bytes), do: event

  defp fit_error_summary(event, max_bytes) do
    marker = %{event | error: %{truncated: true}}

    cond do
      :erlang.external_size(event) <= max_bytes -> event
      :erlang.external_size(marker) <= max_bytes -> marker
      # The existing capture envelope may itself exceed a very small limit.
      # Do not enlarge that envelope when even the failure marker cannot fit.
      true -> %{event | error: nil}
    end
  end

  defp bounded_error(nil), do: nil

  # Errors can carry an entire provider request. Keep failure distinguishable
  # from successful output without retaining messages, bodies, headers or cause.
  # Redaction has already run; even these named fields must have bounded shapes.
  defp bounded_error(error) when is_map(error) do
    error
    |> Map.take([:status, :provider_code, :retryable])
    |> Enum.reduce(%{truncated: true}, fn
      {:status, status}, summary when is_integer(status) and status in 100..599 ->
        Map.put(summary, :status, status)

      {:retryable, retryable}, summary when is_boolean(retryable) ->
        Map.put(summary, :retryable, retryable)

      {:provider_code, code}, summary when is_binary(code) and byte_size(code) <= 64 ->
        if Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, code),
          do: Map.put(summary, :provider_code, code),
          else: summary

      _, summary ->
        summary
    end)
  end

  defp bounded_error(_error), do: %{truncated: true}

  defp bound_snapshot(state) do
    if over?(length(state.events), state.limits.max_events) or
         over?(state.snapshot_bytes, state.limits.max_snapshot_bytes) do
      {last, events} = List.pop_at(state.events, -1)

      bound_snapshot(%{
        state
        | events: events,
          dropped_events: state.dropped_events + 1,
          snapshot_bytes: state.snapshot_bytes - :erlang.external_size(last)
      })
    else
      state
    end
  end

  defp over?(_measured, :infinity), do: false
  defp over?(measured, limit), do: measured > limit

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
