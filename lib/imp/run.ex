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

  The sink's return value is ignored. When a sink raises, throws or exits, the
  run's owner is sent
  `{:imp_run_event_sink_failed, run_id, %{sequence: sequence, kind: kind, reason: {class, reason}}}`,
  where `class` is `:error`, `:throw` or `:exit`, and delivery goes on with the
  next event. Imp does not know whether the sink stored the event before it
  failed (a store call that timed out may have landed), so it does not mark a
  hole itself; the host, which knows its store, decides what to record. The
  event is still in the snapshot.

  Stopping or cancelling a run ends delivery. `stop/1` first waits up to five
  seconds for the sink to finish what it has; `cancel_with_events/3` does not
  wait. Every event the sink had not finished with is then reported the same
  way, with `reason` `:in_sink_when_stopped` for the event the sink was
  holding (it may have been stored) and `:never_handed_to_sink` for each event
  after it. `kind` is `nil` for an event the snapshot no longer holds. These
  reports are in the owner's mailbox when `stop/1` or `cancel_with_events/3`
  returns, after any report the sink's own failures produced, in sequence
  order, and each event is reported at most once. The same reports are sent
  when the sink's process dies outright, for example because it was linked
  to a process that crashed; the run's control then ends too, and so does the
  run: an effect in flight has its cancellation called with
  `{:run_control_ended, reason}` and the task is killed.

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

  @doc """
  Starts an unlinked supervised program run owned by the calling process.

  By default a run takes a place in the machine-wide pool that all Imp tasks
  share, bounded by the `:async_max_workers` setting, and `start/3` waits for a
  place when the pool is full.

  Pass `admission: {pool, limit}` to count the run in a pool the host names
  instead, such as one per agent: at most `limit` runs hold a place in `pool` at
  once, and when it is full `start/3` returns `{:error, :busy}` straight away,
  having stopped the control process it started for the run and started no
  task. The host keeps its own queue and starts the next run when
  one of its runs ends. The limit is read on each start, so a host that changes
  its setting passes the new one. A run in a named pool does not count against
  the machine-wide pool. Tasks it starts inside itself take places in the
  machine-wide pool as usual, except a stream the run enumerates itself
  (`Imp.Tasks.async_stream/3`), which runs one item at a time on the run's own
  place, as it does for any run.
  """
  @spec start(struct(), map() | keyword(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(program, inputs, opts \\ []) when is_list(opts) do
    event_sink = Keyword.get(opts, :event_sink, fn _event -> :ok end)
    authorize = Keyword.get(opts, :authorize)
    authorization_timeout = Keyword.get(opts, :authorization_timeout, 30_000)
    admission = Keyword.get(opts, :admission)

    unless is_function(event_sink, 1) do
      raise ArgumentError, ":event_sink must be an arity-1 function"
    end

    unless is_nil(admission) or
             match?({_pool, limit} when is_integer(limit) and limit > 0, admission) do
      raise ArgumentError,
            ":admission must be {pool, limit} with a positive integer limit, got: " <>
              inspect(admission)
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
      body = fn ->
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
      end

      case start_task(body, admission) do
        {:ok, task} ->
          :ok = Control.attach_task(control, task.pid)
          {:ok, %__MODULE__{task: task, control: control, id: id}}

        {:error, :busy} ->
          Control.force_stop(control)
          {:error, :busy}
      end
    end
  end

  defp start_task(body, nil), do: {:ok, Imp.Tasks.async_nolink(body)}
  defp start_task(body, {pool, limit}), do: Imp.Tasks.async_nolink_in_pool(body, pool, limit)

  @doc """
  Cancels registered effects before terminating the outer supervised task.

  The cancellations are given `timeout` between them, and the task another
  `timeout` to end before it is killed. A cancellation still running after its
  `timeout` is abandoned, so one that never returns delays the cancel by
  `timeout` rather than holding it.
  """
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
    :ok = Control.cancel(run.control, reason, timeout)
    terminate_task(run.task.pid, timeout)
    events = Control.events(run.control)
    Control.force_stop(run.control)
    {:ok, events}
  end

  @doc """
  Releases the event/cancellation control process after a run completes.

  A run still going when its control is released is ended with it, as when
  its control ends for any other reason.
  """
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

  # How long cancellations called without a caller's timeout (the control
  # ending, its owner going down, work registered after a cancel) may take
  # before they are abandoned.
  @cancellation_bound 5_000

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def events(pid), do: GenServer.call(pid, :events)
  def emit(pid, kind, attrs), do: GenServer.call(pid, {:emit, kind, attrs})
  def first_seen?(pid, key), do: GenServer.call(pid, {:first_seen, key})
  def register(pid, fun), do: GenServer.call(pid, {:register, fun})
  def unregister(pid, ref), do: GenServer.call(pid, {:unregister, ref})
  # The control waits up to `timeout` for the cancellations; the call allows
  # for that and for the rest of its work.
  def cancel(pid, reason, timeout) do
    call_timeout = if timeout == :infinity, do: :infinity, else: timeout + 5_000
    GenServer.call(pid, {:cancel, reason, timeout}, call_timeout)
  end

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

    # Delivery is linked, and its death must reach `terminate/2` so that what
    # it had not delivered is reported.
    Process.flag(:trap_exit, true)
    progress = EventDelivery.new_progress()
    {:ok, delivery} = EventDelivery.start_link(Keyword.fetch!(opts, :event_sink), progress)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       delivery: delivery,
       progress: progress,
       reported: 0,
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

  # Work registered after a cancel is cancelled at once, by a process linked
  # to this one that bounds it, so this control goes on answering meanwhile.
  def handle_call({:register, fun}, _from, state) do
    reason = state.cancelled
    spawn_link(fn -> call_cancellations([fun], reason, @cancellation_bound) end)
    {:reply, nil, state}
  end

  def handle_call({:unregister, ref}, _from, state) do
    {:reply, :ok, %{state | cancellables: Map.delete(state.cancellables, ref)}}
  end

  def handle_call({:attach_task, task_pid}, _from, state) when is_pid(task_pid) do
    {:reply, :ok, %{state | task_pid: task_pid, task_monitor: Process.monitor(task_pid)}}
  end

  def handle_call({:cancel, reason, timeout}, _from, %{cancelled: nil} = state) do
    call_cancellations(Map.values(state.cancellables), reason, timeout)

    state =
      record(state, :run_cancelled, %{error: reason, metadata: %{unfinished_effects: :unknown}})

    {:reply, :ok, %{state | cancelled: reason, cancellables: %{}}}
  end

  def handle_call({:cancel, _reason, _timeout}, _from, state), do: {:reply, :ok, state}

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
    call_cancellations(Map.values(state.cancellables), {:owner_down, reason}, @cancellation_bound)

    if is_pid(state.task_pid) and Process.alive?(state.task_pid),
      do: Process.exit(state.task_pid, :kill)

    {:stop, :normal, %{state | cancellables: %{}}}
  end

  def handle_info({EventDelivery, :failed, failure}, state),
    do: {:noreply, report(state, failure)}

  def handle_info({:EXIT, delivery, reason}, %{delivery: delivery} = state),
    do: {:stop, {:event_delivery_exited, reason}, state}

  # Trapping exits is only for delivery's sake; any other exit signal ends
  # the run's control as it would have without trapping.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(reason, state) do
    Process.unlink(state.delivery)
    monitor = Process.monitor(state.delivery)
    Process.exit(state.delivery, :kill)
    receive(do: ({:DOWN, ^monitor, :process, _pid, _reason} -> :ok))
    state |> report_pending_failures() |> report_undelivered()

    # The run does not outlive its control: whatever ended the control (its
    # sink's process dying, a stop), work still in flight is cancelled and the
    # task is ended, rather than left running until it next emits. This comes
    # after the reports, so an owner hears why before it sees the task end.
    # The cancellations come before the kill because some of what they end is
    # held by processes that end with the task (an RLM's model call is its
    # budget's to end); they are bounded, so one that does not return cannot
    # keep the task going.
    call_cancellations(
      Map.values(state.cancellables),
      {:run_control_ended, reason},
      @cancellation_bound
    )

    if is_pid(state.task_pid) and Process.alive?(state.task_pid),
      do: Process.exit(state.task_pid, :kill)

    :ok
  end

  # Every report reaches the owner from this process, so the owner's reports
  # are in sequence order and each event is reported once.
  defp report(state, failure) do
    send(state.owner, {:imp_run_event_sink_failed, state.id, failure})
    %{state | reported: failure.sequence + 1}
  end

  # Delivery sends a failure here before it records the event as finished,
  # and it is dead, so every failure it sent is already in this mailbox.
  defp report_pending_failures(state) do
    receive do
      {EventDelivery, :failed, failure} -> state |> report(failure) |> report_pending_failures()
    after
      0 -> state
    end
  end

  # Delivery is dead, so its progress no longer moves. Every event it had not
  # finished and that was not reported as failed is reported now: the one the
  # sink was holding may have been stored, and the ones after it were never
  # handed over.
  defp report_undelivered(state) do
    {handed, finished} = EventDelivery.progress(state.progress)
    first = max(finished, state.reported)

    kinds =
      for event <- state.events,
          event.sequence >= first,
          into: %{},
          do: {event.sequence, event.kind}

    Enum.reduce(first..(state.sequence - 1)//1, state, fn sequence, state ->
      reason = if sequence < handed, do: :in_sink_when_stopped, else: :never_handed_to_sink
      report(state, %{sequence: sequence, kind: Map.get(kinds, sequence), reason: reason})
    end)
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

  # Each cancellation runs in a process of its own, all at once, so one that
  # does not return holds neither the others, nor this control, nor what the
  # caller does next. Past `bound` those still running are killed: whether
  # their effects were cancelled is as unknown as it was. They are linked to
  # the caller, so they end with it however it ends; `safe_cancel/2` ends them
  # normally whatever the cancellation does, so the link reports nothing else.
  defp call_cancellations([], _reason, _bound), do: :ok

  defp call_cancellations(funs, reason, bound) do
    deadline = if bound == :infinity, do: :infinity, else: now_ms() + bound

    running =
      Map.new(funs, fn fun ->
        pid = spawn_link(fn -> safe_cancel(fun, reason) end)
        {Process.monitor(pid), pid}
      end)

    await_cancellations(running, deadline)
  end

  defp await_cancellations(running, _deadline) when map_size(running) == 0, do: :ok

  defp await_cancellations(running, deadline) do
    receive do
      {:DOWN, monitor, :process, _pid, _reason} when is_map_key(running, monitor) ->
        await_cancellations(Map.delete(running, monitor), deadline)
    after
      remaining(deadline) ->
        Enum.each(running, fn {monitor, pid} ->
          Process.demonitor(monitor, [:flush])
          Process.unlink(pid)
          Process.exit(pid, :kill)
        end)
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)

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

  # Two counters shared with the run's control: how many events have been
  # handed to the sink, and how many the sink has finished with (returned,
  # raised, thrown or exited). The control reads them after this process is
  # dead to report what was not delivered. A sink failure is sent to the
  # control, which reports it to the owner, before the event counts as
  # finished; so once this process is dead the control holds every failure it
  # sent and can tell which events are already reported.
  @handed 1
  @finished 2

  def new_progress, do: :counters.new(2, [:atomics])

  def progress(progress),
    do: {:counters.get(progress, @handed), :counters.get(progress, @finished)}

  def start_link(sink, progress),
    do: GenServer.start_link(__MODULE__, {sink, self(), progress})

  def deliver(pid, event), do: GenServer.cast(pid, {:deliver, event})
  def barrier(pid, receiver, tag), do: GenServer.cast(pid, {:barrier, receiver, tag})
  def drain(pid, timeout), do: GenServer.call(pid, :drain, timeout)

  @impl true
  def init({sink, control, progress}),
    do: {:ok, %{sink: sink, control: control, progress: progress}}

  @impl true
  def handle_cast({:deliver, event}, state) do
    :counters.put(state.progress, @handed, event.sequence + 1)

    with {:error, reason} <- sink(state, event) do
      failure = %{sequence: event.sequence, kind: event.kind, reason: reason}
      send(state.control, {__MODULE__, :failed, failure})
    end

    :counters.put(state.progress, @finished, event.sequence + 1)
    {:noreply, state}
  end

  def handle_cast({:barrier, receiver, tag}, state) do
    send(receiver, {:imp_run_barrier, tag})
    {:noreply, state}
  end

  @impl true
  def handle_call(:drain, _from, state), do: {:reply, :ok, state}

  defp sink(state, event) do
    _ = state.sink.(event)
    :ok
  rescue
    error -> {:error, {:error, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
