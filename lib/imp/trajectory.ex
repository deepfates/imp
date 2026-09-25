defmodule Imp.Trajectory do
  @moduledoc """
  ATIF-v1.8 projection of ordered native `Imp.Run.Event` observations.

  `to_atif/2` projects one run's ordered events into a JSON-encodable ATIF
  document. The initial model context keeps its actual message roles and is
  marked as copied context; every model request is also listed in
  `extra.model_requests`. A model response step carries the observed typed
  output. Lifecycle events and capture gaps become entries in
  `extra.diagnostics` rather than dialogue steps. `extra.terminal_event` is
  the kind of the event that ended the run (`"run_finished"`, `"run_failed"`,
  `"run_cancelled"`), or `"unknown"` when the events hold none.

  A tool result's `extra.outcome`, on the result and on its call step, is the
  `t:Imp.Tool.outcome/0` the loop recorded on the `:tool_result` event
  (`metadata.outcome`); an event that carries none, and a call whose result was
  not captured, is `"unknown"`.

  Stored event maps are read by their `"kind"`. A kind that is not one of
  `Imp.Run.Event.kinds/0`, such as one a host emitted itself, keeps its stored
  string and becomes a diagnostic entry.

  Semantic tool dispatches have `llm_call_count: 0`; a model response leaves the
  count null, because a request may have been served from a cache. Inference
  counts, metrics, reasoning and tool results are never synthesized from missing
  evidence. A tool observation attaches to its call step as ATIF requires,
  retaining the native sequence and time; step tool call IDs are scoped by run
  and event sequence. A provider tool call ID may be reused once its result has
  arrived, but an overlapping reuse raises `ArgumentError`.

  The document is a projection, not a replay and not a durable effect ledger.
  Streaming paths that bypass `Imp.LM.request/2` do not produce complete model
  episodes. Redaction runs again on export, including caller metadata; prompts
  and results are still private application data.
  """

  alias Imp.Run.Event

  @doc "Builds a JSON-encodable ATIF document from one run's ordered events or stored event maps."
  def to_atif(events, opts \\ []) when is_list(events) do
    events = Enum.map(events, &native_event/1)
    validate_events!(events)
    [first | _] = events

    state =
      Enum.reduce(events, %{steps: [], pending: %{}, requests: [], diagnostics: []}, &project/2)

    terminal =
      Enum.find(Enum.reverse(events), &(&1.kind in [:run_finished, :run_failed, :run_cancelled]))

    steps =
      case state.steps do
        [] ->
          [
            %{
              source: "system",
              message: "No complete interaction was captured.",
              extra: %{diagnostic: true}
            }
          ]

        steps ->
          steps
      end

    %{
      schema_version: "ATIF-v1.8",
      session_id: first.run_id,
      trajectory_id: first.run_id,
      agent:
        Keyword.get(opts, :agent, %{name: "Imp", version: to_string(Application.spec(:imp, :vsn))}),
      steps:
        Enum.with_index(steps, 1) |> Enum.map(fn {step, id} -> Map.put(step, :step_id, id) end),
      extra: %{
        terminal_event: if(terminal, do: terminal.kind, else: :unknown),
        model_requests: state.requests,
        diagnostics: state.diagnostics,
        capture: "Native Imp execution observations; model inference counts are unknown"
      }
    }
    |> Imp.Redaction.redact()
    |> Imp.Observability.Inspection.json_safe()
  end

  defp project(%Event{kind: :model_request} = event, state) do
    request = Map.merge(origin(event), %{messages: event.input, metadata: event.metadata})
    steps = if state.requests == [], do: initial_context(event), else: []
    state = %{state | steps: state.steps ++ steps, requests: state.requests ++ [request]}

    if truncated?(event),
      do: diagnostic(state, event, %{uncaptured_model_request: true}),
      else: state
  end

  defp project(%Event{kind: :tool_result} = event, state) do
    case Map.pop(state.pending, event.tool_call_id) do
      {nil, _} ->
        diagnostic(state, event, %{unmatched_tool_result: true})

      {index, pending} ->
        steps =
          List.update_at(state.steps, index, fn step ->
            [call] = step.tool_calls

            result = %{
              source_call_id: call.tool_call_id,
              extra: Map.merge(origin(event), %{outcome: result_outcome(event)})
            }

            result =
              if truncated?(event),
                do: result,
                else:
                  Map.put(
                    result,
                    :content,
                    text(if(is_nil(event.error), do: event.output, else: event.error))
                  )

            step
            |> Map.put(:observation, %{results: [result]})
            |> Map.update!(:extra, &Map.put(&1, :outcome, result_outcome(event)))
          end)

        %{state | steps: steps, pending: pending}
    end
  end

  defp project(%Event{kind: :tool_call} = event, state) do
    if Map.has_key?(state.pending, event.tool_call_id),
      do:
        raise(
          ArgumentError,
          "overlapping tool call IDs are ambiguous; preserve distinct native IDs"
        )

    unless is_binary(event.tool_call_id) and not is_nil(event.tool_name),
      do: raise(ArgumentError, "tool call requires its native identity and name")

    if truncated?(event) do
      diagnostic(state, event, %{uncaptured_tool_arguments: true})
    else
      step = %{
        source: "agent",
        message: "",
        timestamp: event.timestamp,
        llm_call_count: 0,
        tool_calls: [
          %{
            tool_call_id: "#{event.run_id}:#{event.sequence}",
            function_name: to_string(event.tool_name),
            arguments: event.input || %{},
            extra: %{native_tool_call_id: event.tool_call_id}
          }
        ],
        extra: Map.merge(origin(event), %{outcome: :unknown})
      }

      unless is_map(event.input) or is_nil(event.input),
        do: raise(ArgumentError, "tool arguments must be a captured map")

      %{
        state
        | steps: state.steps ++ [step],
          pending: Map.put(state.pending, event.tool_call_id, length(state.steps))
      }
    end
  end

  defp project(%Event{kind: :model_response, error: nil} = event, state) do
    if truncated?(event) do
      diagnostic(state, event, %{uncaptured_model_response: true})
    else
      output =
        case event.output do
          [one] -> one
          other -> other
        end

      step = %{
        source: "agent",
        message: text(output),
        timestamp: event.timestamp,
        llm_call_count: nil,
        extra: Map.merge(origin(event), %{model_observation: event.metadata})
      }

      %{state | steps: state.steps ++ [step]}
    end
  end

  defp project(%Event{kind: :reasoning} = event, state) do
    if truncated?(event) or is_nil(event.reasoning) do
      diagnostic(state, event, %{uncaptured_reasoning: true})
    else
      step = %{
        source: "agent",
        message: "",
        timestamp: event.timestamp,
        llm_call_count: nil,
        reasoning_content: text(event.reasoning),
        extra: origin(event)
      }

      %{state | steps: state.steps ++ [step]}
    end
  end

  defp project(event, state), do: diagnostic(state, event, %{})

  defp diagnostic(state, event, extra) do
    # Prediction and input payloads have their own native storage. A terminal
    # lifecycle record must not become a second fabricated assistant response.
    entry =
      Map.merge(origin(event), Map.merge(%{error: event.error, metadata: event.metadata}, extra))

    %{state | diagnostics: state.diagnostics ++ [entry]}
  end

  defp initial_context(%Event{input: messages} = event) when is_list(messages) do
    Enum.map(messages, fn message ->
      role = get(message, :role)

      source =
        case role do
          role when role in [:user, "user"] -> "user"
          role when role in [:assistant, "assistant"] -> "agent"
          _ -> "system"
        end

      %{
        source: source,
        message: text(get(message, :content)),
        is_copied_context: true,
        timestamp: event.timestamp,
        extra: Map.merge(origin(event), %{context_role: role})
      }
    end)
  end

  defp initial_context(_), do: []

  defp origin(event),
    do: %{
      event_kind: event.kind,
      event_sequence: event.sequence,
      event_timestamp: event.timestamp,
      component: event.component
    }

  defp truncated?(event), do: get(get(event.metadata, :capture) || %{}, :truncated) == true

  defp result_outcome(event) do
    recorded = get(event.metadata, :outcome)
    Enum.find(Imp.Tool.outcomes(), :unknown, &(&1 == recorded or to_string(&1) == recorded))
  end

  defp native_event(%Event{} = event), do: event

  defp native_event(map) when is_map(map) do
    stored = get(map, :kind)
    kind = Enum.find(Event.kinds(), stored, &(to_string(&1) == stored))

    attrs =
      Map.new(Map.keys(Map.from_struct(%Event{run_id: "", sequence: 0, kind: nil})), fn key ->
        {key, get(map, key)}
      end)

    struct!(Event, Map.merge(attrs, %{kind: kind, metadata: get(map, :metadata) || %{}}))
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp get(_, _), do: nil

  defp validate_events!([]),
    do: raise(ArgumentError, "ATIF requires a nonempty run event sequence")

  defp validate_events!([%Event{run_id: id} | _] = events) do
    sequences =
      Enum.map(events, fn
        %Event{run_id: ^id, sequence: sequence} when is_integer(sequence) -> sequence
        _ -> raise ArgumentError, "ATIF requires events from exactly one run"
      end)

    unless sequences == Enum.sort(Enum.uniq(sequences)),
      do: raise(ArgumentError, "ATIF requires strictly ordered unique event sequences")
  end

  defp text(value) when is_binary(value), do: value
  defp text(nil), do: ""

  defp text(value),
    do: value |> Imp.Observability.Inspection.json_safe() |> Jason.encode!(pretty: true)
end
