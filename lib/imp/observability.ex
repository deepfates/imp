defmodule Imp.Observability do
  @moduledoc """
  Public inspection, optimizer progress, and Imp-scoped logging controls.

  All history inspection is redacted by default. Optimizer subscriptions use
  telemetry and deliver messages without owning optimizer processes.
  """

  require Logger

  alias Imp.Observability.{Inspection, Status}
  alias Imp.Optimizer.Report, as: OptimizerReport

  @logging_key {__MODULE__, :logging_enabled}
  @optimizer_events [
    [:imp, :optimizer, :progress],
    [:imp, :optimizer, :trial, :start],
    [:imp, :optimizer, :trial, :stop],
    [:imp, :optimizer, :trial, :exception]
  ]

  @default_trace_events [
    [:imp, :lm, :start],
    [:imp, :lm, :stop],
    [:imp, :lm, :exception],
    [:imp, :lm, :transport, :attempt],
    [:imp, :lm, :stream, :start],
    [:imp, :lm, :stream, :chunk],
    [:imp, :lm, :stream, :stop],
    [:imp, :lm, :stream, :exception],
    [:imp, :tool, :start],
    [:imp, :tool, :stop],
    [:imp, :tool, :exception],
    [:imp, :retriever, :start],
    [:imp, :retriever, :stop],
    [:imp, :retriever, :exception],
    [:imp, :optimizer, :progress],
    [:imp, :optimizer, :trial, :start],
    [:imp, :optimizer, :trial, :stop],
    [:imp, :optimizer, :trial, :exception],
    [:imp, :training, :submit, :start],
    [:imp, :training, :submit, :stop],
    [:imp, :training, :submit, :exception],
    [:imp, :training, :refresh, :start],
    [:imp, :training, :refresh, :stop],
    [:imp, :training, :refresh, :exception],
    [:imp, :training, :cancel, :start],
    [:imp, :training, :cancel, :stop],
    [:imp, :training, :cancel, :exception]
  ]

  defmodule Trace do
    @moduledoc "Result and ordered, redacted telemetry events captured by `Imp.trace/2`."
    @enforce_keys [:result, :events]
    defstruct [:result, :events]
  end

  defmodule ProgressSubscription do
    @moduledoc "Handle returned by `Imp.Observability.subscribe_optimizer/1`."
    @enforce_keys [:id, :owner]
    defstruct [:id, :owner]
  end

  @inspection_schema [
    limit: [type: :pos_integer, default: 50],
    max_bytes: [type: :pos_integer, default: 16_384],
    redact: [type: :boolean, default: true]
  ]

  @doc "Renders recent conversation turns or provider-call history with redaction by default."
  def inspect_history(history, opts \\ []) do
    opts =
      Imp.Options.validate!(
        opts,
        [
          limit: [type: :pos_integer, default: 10],
          max_bytes: [type: :pos_integer, default: 16_384],
          redact: [type: :boolean, default: true],
          io: [type: :any, default: nil]
        ],
        "Imp.Observability.inspect_history/2"
      )

    if provider_history?(history) do
      render_inspection({:provider, history},
        limit: opts[:limit],
        max_bytes: opts[:max_bytes],
        redact: opts[:redact],
        io: opts[:io]
      )
    else
      history = Imp.History.new(history)
      history = if opts[:redact], do: Imp.History.redact(history), else: history

      rendered =
        history
        |> Imp.History.messages()
        |> Enum.take(-opts[:limit])
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {turn, index} ->
          "Turn #{index}\n" <> Jason.encode!(turn, pretty: true)
        end)

      if opts[:io], do: IO.write(opts[:io], rendered)
      rendered
    end
  end

  @doc """
  Returns one normalized, redacted inspection snapshot.

  Tagged tuples make otherwise ambiguous lists explicit: `{:provider, calls}`,
  `{:tool, history}`, `{:rlm, trace}`, and `{:optimizer, report}`. Predictions,
  conversation histories, optimizer reports, and traces are recognized directly.
  Redaction is enabled by default and each payload is bounded by `:max_bytes`.
  """
  def inspect_artifact(value, opts \\ []) do
    opts =
      Imp.Options.validate!(
        opts,
        @inspection_schema,
        "Imp.Observability.inspect_artifact/2"
      )

    value
    |> normalize_inspection()
    |> then(fn {kind, status, summary, entries} ->
      Inspection.new(kind, status, summary, entries, opts)
    end)
  end

  @doc "Renders an inspection snapshot as stable, pretty JSON."
  def render_inspection(value, opts \\ []) do
    inspection_opts = Keyword.drop(opts, [:io])

    inspection =
      if match?(%Inspection{}, value), do: value, else: inspect_artifact(value, inspection_opts)

    rendered = inspection |> Inspection.json_safe() |> Jason.encode!(pretty: true)

    case Keyword.get(opts, :io) do
      nil -> :ok
      io -> IO.write(io, rendered)
    end

    rendered
  end

  @doc "Normalizes optimizer telemetry, reports, predictions, and provider states into status data."
  def status(value) do
    value
    |> normalize_status()
    |> redact_status()
  end

  @doc """
  Collects selected redacted telemetry emitted in this function's trace context.

  Owned `Imp.Tasks` children inherit correlation; unrelated processes do not.
  Ordinary `Task`/`spawn` children require explicit `Imp.Telemetry.with_context(context, fun)`
  propagation. Await owned children before returning. Nested traces have their
  own correlation and do not contaminate their enclosing trace.
  """
  def trace(fun, opts \\ [])

  def trace(fun, opts) when is_function(fun, 0) do
    events = Keyword.get(opts, :events, @default_trace_events)

    unless is_list(events) and Enum.all?(events, &is_list/1) do
      raise ArgumentError,
            "Imp.Observability.trace/2 expects :events to be a list of event names"
    end

    id = "imp-trace-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> [] end)
    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle_trace_event/4, {agent, id})

    try do
      result = Imp.Telemetry.with_trace(id, fun)
      %Trace{result: result, events: Agent.get(agent, &Enum.reverse/1)}
    after
      :telemetry.detach(id)
      Agent.stop(agent)
    end
  end

  def trace(fun, _opts) do
    raise ArgumentError,
          "Imp.Observability.trace/2 expects a zero-arity function; got: #{inspect(fun)}"
  end

  @doc false
  def handle_trace_event(event, measurements, %{trace_id: id} = metadata, {agent, id}) do
    event = {event, Imp.Redaction.redact(measurements), Imp.Redaction.redact(metadata)}
    Agent.update(agent, &[event | &1])
  end

  def handle_trace_event(_event, _measurements, _metadata, _capture), do: :ok

  @doc "Subscribes the owner process to normalized optimizer progress events."
  def subscribe_optimizer(opts \\ []) do
    owner = Keyword.get(opts, :owner, self())

    unless is_pid(owner) do
      raise ArgumentError, "Imp.Observability.subscribe_optimizer/1 expects :owner to be a pid"
    end

    id = "imp-optimizer-progress-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(id, @optimizer_events, &__MODULE__.handle_optimizer_event/4, owner)

    %ProgressSubscription{id: id, owner: owner}
  end

  @doc "Detaches an optimizer progress subscription."
  def unsubscribe_optimizer(%ProgressSubscription{id: id}) do
    :telemetry.detach(id)
  end

  def unsubscribe_optimizer(subscription) do
    raise ArgumentError,
          "Imp.Observability.unsubscribe_optimizer/1 expects a ProgressSubscription; got: #{inspect(subscription)}"
  end

  @doc false
  def handle_optimizer_event(event, measurements, metadata, owner) do
    measurements = Imp.Redaction.redact(measurements)
    metadata = Imp.Redaction.redact(metadata)
    status = status({event, measurements, metadata})
    send(owner, {:imp_optimizer_progress, event, measurements, metadata})
    send(owner, {:imp_status, status})
  end

  @doc "Enables Imp application logging."
  def enable_logging do
    :persistent_term.put(@logging_key, true)
    :ok
  end

  @doc "Disables Imp application logging without changing host Logger configuration."
  def disable_logging do
    :persistent_term.put(@logging_key, false)
    :ok
  end

  @doc "Returns whether Imp-scoped logging is enabled."
  def logging_enabled?, do: :persistent_term.get(@logging_key, true)

  @doc "Emits a redacted Imp log entry when Imp-scoped logging is enabled."
  def log(level, message, metadata \\ []) when is_binary(message) do
    if logging_enabled?() do
      metadata = metadata |> Map.new() |> Imp.Redaction.redact() |> Map.to_list()
      Logger.log(level, message, metadata)
    end

    :ok
  end

  defp normalize_inspection(%Imp.History{} = history) do
    entries = Enum.map(Imp.History.messages(history), &{:conversation, &1})
    {:history, :ok, %{turn_count: length(entries)}, entries}
  end

  defp normalize_inspection(%Imp.Prediction{} = prediction) do
    metadata = prediction.metadata
    provider = map_entries(Map.get(metadata, :trace), :provider)
    tools = prediction |> Imp.Prediction.get(:history) |> history_entries(:tool)
    rlm = metadata |> Map.get(:rlm_trace) |> list_entries(:rlm)

    optimizer =
      metadata
      |> Map.get(:optimizer_report)
      |> optimizer_entries()

    entries = provider ++ tools ++ rlm ++ optimizer

    summary = %{
      fields: prediction.fields |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      completion_count: length(prediction.completions),
      score: prediction.score,
      entry_count: length(entries)
    }

    {:prediction, prediction_status(prediction), summary, entries}
  end

  defp normalize_inspection(%OptimizerReport{} = report),
    do: normalize_optimizer(report)

  defp normalize_inspection(%Trace{} = trace) do
    entries =
      Enum.map(trace.events, fn {event, measurements, metadata} ->
        {:telemetry, %{event: event, measurements: measurements, metadata: metadata}}
      end)

    {:trace, result_status(trace.result), %{event_count: length(entries)}, entries}
  end

  defp normalize_inspection(%Imp.Streaming.Messages.StatusMessage{} = message) do
    {:status, :ok, %{level: message.level}, [{:status, message}]}
  end

  defp normalize_inspection({:provider, calls}) when is_list(calls) do
    entries = Enum.map(calls, fn call -> {:provider, normalize_provider_call(call)} end)
    {:provider, :ok, %{call_count: length(entries)}, entries}
  end

  defp normalize_inspection({:tool, history}) do
    entries = history_entries(history, :tool)
    {:tool, :ok, %{event_count: length(entries)}, entries}
  end

  defp normalize_inspection({:rlm, trace}) when is_list(trace) do
    entries = list_entries(trace, :rlm)
    {:rlm, :ok, rlm_summary(trace), entries}
  end

  defp normalize_inspection({:optimizer, report}), do: normalize_optimizer(report)

  defp normalize_inspection(value) do
    raise ArgumentError,
          "Imp.Observability.inspect_artifact/2 does not recognize: #{safe_inspect(value)}"
  end

  defp normalize_optimizer(%OptimizerReport{} = report) do
    entries = optimizer_entries(report)

    summary = %{
      optimizer: report.optimizer,
      best_score: report.best_score,
      candidate_count: report.candidate_count,
      error_count: length(report.errors)
    }

    status = if report.errors == [], do: :ok, else: :with_errors
    {:optimizer, status, summary, entries}
  end

  defp normalize_optimizer(report) when is_map(report) do
    report |> OptimizerReport.new() |> normalize_optimizer()
  end

  defp normalize_optimizer(report) do
    raise ArgumentError, "optimizer inspection expects a report, got: #{safe_inspect(report)}"
  end

  defp normalize_provider_call(call) when is_map(call) do
    messages = Map.get(call, :messages, Map.get(call, "messages"))
    prompt = Map.get(call, :prompt, Map.get(call, "prompt"))

    call
    |> Map.put_new(
      :messages,
      messages || if(prompt, do: [%{role: :user, content: prompt}], else: [])
    )
    |> Map.delete(:prompt)
    |> Map.delete("prompt")
  end

  defp normalize_provider_call(call), do: %{output: call}

  defp provider_history?(history) when is_list(history) and history != [] do
    Enum.all?(history, fn
      call when is_map(call) ->
        has_key?(call, :outputs) and (has_key?(call, :messages) or has_key?(call, :prompt))

      _call ->
        false
    end)
  end

  defp provider_history?(_history), do: false

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp map_entries(nil, _source), do: []
  defp map_entries(value, source), do: [{source, value}]

  defp list_entries(nil, _source), do: []
  defp list_entries(values, source) when is_list(values), do: Enum.map(values, &{source, &1})
  defp list_entries(value, source), do: [{source, value}]

  defp history_entries(nil, _source), do: []

  defp history_entries(%Imp.History{} = history, source),
    do: list_entries(Imp.History.messages(history), source)

  defp history_entries(history, source) when is_list(history), do: list_entries(history, source)
  defp history_entries(history, source), do: [{source, history}]

  defp optimizer_entries(nil), do: []

  defp optimizer_entries(%OptimizerReport{} = report) do
    Enum.map(report.candidates, &{:optimizer_candidate, &1}) ++
      Enum.map(report.errors, &{:optimizer_error, &1})
  end

  defp optimizer_entries(report) when is_map(report),
    do: report |> OptimizerReport.new() |> optimizer_entries()

  defp optimizer_entries(report), do: [{:optimizer, report}]

  defp rlm_summary(trace) do
    actions =
      trace
      |> Enum.map(&Map.get(&1, :action, Map.get(&1, "action")))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    %{event_count: length(trace), actions: actions}
  end

  # The termination reasons of a run that ended with its outputs. ReAct and
  # ReActV2 end with `:submit`, `:forced_submit` or `:direct`; ReActV2 also
  # ends with prose (`:answered`), the text of the last request of an
  # interrupted turn (`:last_prose`) and a terminal tool (`:finished_by_tool`).
  # Every other reason names why a run stopped without them.
  @complete_terminations [
    :submit,
    :forced_submit,
    :direct,
    :answered,
    :last_prose,
    :finished_by_tool,
    nil
  ]

  defp prediction_status(%Imp.Prediction{} = prediction) do
    if Imp.Prediction.get(prediction, :termination_reason) in @complete_terminations,
      do: :ok,
      else: :incomplete
  end

  defp result_status({:error, _reason}), do: :error
  defp result_status(_result), do: :ok

  defp normalize_status({event, measurements, metadata})
       when is_list(event) and is_map(measurements) and is_map(metadata) do
    state = event_state(List.last(event), metadata)
    phase = event |> Enum.drop(1) |> Enum.join("_")
    completed = first_integer(measurements, [:completed, :completed_generations, :current, :step])
    total = first_integer(measurements, [:total, :total_generations, :max, :budget])

    %Status{
      state: state,
      phase: phase,
      completed: completed,
      total: total,
      message: status_message(state, phase, completed, total),
      metadata: Map.merge(metadata, Map.drop(measurements, [:completed, :total]))
    }
  end

  defp normalize_status(%OptimizerReport{} = report) do
    state = if report.errors == [], do: :succeeded, else: :failed

    %Status{
      state: state,
      phase: :optimizer,
      completed: report.candidate_count,
      total: report.candidate_count,
      message: "optimizer #{state}: #{report.candidate_count} candidates",
      metadata: %{
        optimizer: report.optimizer,
        best_score: report.best_score,
        error_count: length(report.errors)
      }
    }
  end

  defp normalize_status(%Imp.Prediction{} = prediction) do
    state = if prediction_status(prediction) == :ok, do: :succeeded, else: :failed

    %Status{
      state: state,
      phase: :prediction,
      completed: 1,
      total: 1,
      message: "prediction #{state}",
      metadata: %{score: prediction.score, fields: Map.keys(prediction.fields)}
    }
  end

  defp normalize_status(status) when is_map(status) do
    state = Map.get(status, :state, Map.get(status, "state", :unknown))
    phase = Map.get(status, :phase, Map.get(status, "phase", :provider))
    completed = Map.get(status, :completed, Map.get(status, "completed"))
    total = Map.get(status, :total, Map.get(status, "total"))

    %Status{
      state: normalize_state(state),
      phase: normalize_phase(phase),
      completed: completed,
      total: total,
      message: Map.get(status, :message, Map.get(status, "message", to_string(state))),
      metadata:
        Map.drop(status, [
          :state,
          "state",
          :phase,
          "phase",
          :completed,
          "completed",
          :total,
          "total",
          :message,
          "message"
        ])
    }
  end

  defp normalize_status(value) do
    raise ArgumentError,
          "Imp.Observability.status/1 does not recognize: #{safe_inspect(value)}"
  end

  defp event_state(:start, _metadata), do: :running
  defp event_state(:progress, _metadata), do: :running
  defp event_state(:stop, %{result: :error}), do: :failed
  defp event_state(:stop, _metadata), do: :succeeded
  defp event_state(:exception, _metadata), do: :failed
  defp event_state(:cancel, _metadata), do: :cancelled
  defp event_state(_event, metadata), do: normalize_state(Map.get(metadata, :state, :unknown))

  defp normalize_state(state)
       when state in [:pending, :running, :succeeded, :failed, :cancelled, :unknown], do: state

  defp normalize_state(state) when state in [:complete, :completed, :success, :ok], do: :succeeded
  defp normalize_state(state) when state in [:error, :exception], do: :failed

  defp normalize_state(state) when is_binary(state) do
    state |> String.downcase() |> String.to_existing_atom() |> normalize_state()
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_state(_state), do: :unknown

  defp normalize_phase(phase) when is_atom(phase) or is_binary(phase), do: phase

  defp normalize_phase(_phase), do: :provider

  defp first_integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> nil
      end
    end)
  end

  defp status_message(state, phase, completed, total) do
    progress =
      case {completed, total} do
        {completed, total} when is_integer(completed) and is_integer(total) ->
          " #{completed}/#{total}"

        {completed, nil} when is_integer(completed) ->
          " #{completed}"

        _other ->
          ""
      end

    "#{phase}: #{state}#{progress}"
  end

  defp redact_status(%Status{} = status) do
    %{
      status
      | metadata: Imp.Redaction.redact(status.metadata),
        message: Imp.Redaction.redact(status.message)
    }
  end

  defp safe_inspect(value),
    do: value |> Imp.Redaction.redact() |> redact_error_tuples() |> Kernel.inspect()

  defp redact_error_tuples(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&(Imp.Redaction.redact(&1) |> redact_error_tuples()))
    |> List.to_tuple()
  end

  defp redact_error_tuples(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, redact_error_tuples(nested)} end)

  defp redact_error_tuples(value) when is_list(value), do: Enum.map(value, &redact_error_tuples/1)
  defp redact_error_tuples(value), do: value
end
