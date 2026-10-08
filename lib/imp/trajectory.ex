defmodule Imp.Trajectory do
  @moduledoc """
  ATIF-v1.8 projection of ordered native `Imp.Run.Event` observations.

  `to_atif/2` projects one run's ordered events into a JSON-encodable ATIF
  document that reads as the model saw the run:

    * The first request's messages are steps marked as copied context, with
      their roles, an assistant message's tool calls and reasoning, and each
      tool message as the observation of the call it answers. A user or system
      message a later request appends is a step of its own.
    * Each model response is one agent step (`llm_call_count: 1`, or null for
      a response served from Imp's cache) with the response text as
      `message`, the provider's own reasoning as `reasoning_content`, the
      calls the loop dispatched for it as `tool_calls`, `model_name`, and
      `metrics` from its usage and cost.
    * A tool result's `content` is the tool message the model read in the
      next request, which may be shortened or rendered differently from what
      the tool returned. `extra.seen_by_model` says whether a later request
      carried it; when the two differ, the tool's own output is kept in
      `extra.output`.
    * A tool call no model response asked for, such as one a host dispatches
      itself, is a step of its own with `llm_call_count: 0`.
    * `agent.tool_definitions` holds every tool roster the run sent (from
      `:tools_sent`), `agent.model_name` the model when every request used the
      same one, and `final_metrics` the run's token and cost totals where
      every response reported them.

  Every model request is also listed whole in `extra.model_requests`.
  Lifecycle events and capture gaps become entries in `extra.diagnostics`
  rather than dialogue steps. A loop's `:reasoning` event is the visible
  thought a step wrote, which the response already carries, so it is kept on
  that response step as `extra.next_thought`. `extra.terminal_event` is the
  kind of the event that ended the run (`"run_finished"`, `"run_failed"`,
  `"run_cancelled"`), or `"unknown"` when the events hold none.

  A tool result's `extra.outcome`, on the result and on its call, is the
  `t:Imp.Tool.outcome/0` the loop recorded on the `:tool_result` event
  (`metadata.outcome`); an event that carries none, and a call whose result was
  not captured, is `"unknown"`.

  Stored event maps are read by their `"kind"`. A kind that is not one of
  `Imp.Run.Event.kinds/0`, such as one a host emitted itself, keeps its stored
  string and becomes a diagnostic entry.

  Inference counts, metrics, reasoning and tool results are never synthesized
  from missing evidence. Step tool call IDs are scoped by run and event
  sequence, with the provider's ID in `extra.native_tool_call_id`. A provider
  tool call ID may be reused once its result has arrived, but an overlapping
  reuse raises `ArgumentError`.

  The document is a projection, not a replay and not a durable effect ledger.
  Redaction runs again on export, including caller metadata; prompts
  and results are still private application data.
  """

  alias Imp.Run.Event

  @doc "Builds a JSON-encodable ATIF document from one run's ordered events or stored event maps."
  def to_atif(events, opts \\ []) when is_list(events) do
    events = Enum.map(events, &native_event/1)
    validate_events!(events)
    [first | _] = events

    state =
      events
      |> Enum.reduce(
        %{
          steps: [],
          pending: %{},
          unseen: [],
          offered: [],
          response: nil,
          requests: [],
          diagnostics: []
        },
        &project/2
      )
      |> resolve_unseen([])

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
      agent: Map.merge(agent(events), Keyword.get(opts, :agent, %{})),
      steps:
        Enum.with_index(steps, 1) |> Enum.map(fn {step, id} -> Map.put(step, :step_id, id) end),
      final_metrics: final_metrics(events, length(steps)),
      extra: %{
        terminal_event: if(terminal, do: terminal.kind, else: :unknown),
        model_requests: Enum.reverse(state.requests),
        diagnostics: state.diagnostics,
        capture: "Native Imp execution observations"
      }
    }
    |> Imp.Redaction.redact()
    |> Imp.Observability.Inspection.json_safe()
  end

  defp project(%Event{kind: :model_request} = event, state) do
    request = Map.merge(origin(event), %{messages: event.input, metadata: event.metadata})

    state =
      if truncated?(event),
        do: state,
        else: resolve_unseen(state, List.wrap(event.input))

    steps =
      case state.requests do
        [] -> context_steps(event)
        [previous | _] -> appended_steps(previous.messages, event)
      end

    state = %{
      state
      | steps: state.steps ++ steps,
        requests: [request | state.requests],
        offered: [],
        response: nil
    }

    if truncated?(event),
      do: diagnostic(state, event, %{uncaptured_model_request: true}),
      else: state
  end

  defp project(%Event{kind: :tool_result} = event, state) do
    case Map.pop(state.pending, event.tool_call_id) do
      {nil, _} ->
        diagnostic(state, event, %{unmatched_tool_result: true})

      {{index, call_index}, pending} ->
        outcome = result_outcome(event)
        output = if(is_nil(event.error), do: event.output, else: event.error)

        steps =
          List.update_at(state.steps, index, fn step ->
            call = Enum.at(step.tool_calls, call_index)

            result = %{
              source_call_id: call.tool_call_id,
              extra: Map.merge(origin(event), %{outcome: outcome})
            }

            result =
              if truncated?(event), do: result, else: Map.put(result, :content, text(output))

            results = get_in(step, [:observation, :results]) || []

            step
            |> Map.put(:observation, %{results: results ++ [result]})
            |> Map.put(
              :tool_calls,
              List.update_at(step.tool_calls, call_index, &put_outcome(&1, outcome))
            )
            |> then(fn step ->
              if step.llm_call_count == 0, do: put_outcome(step, outcome), else: step
            end)
          end)

        result_index = length(get_in(Enum.at(steps, index), [:observation, :results])) - 1

        %{
          state
          | steps: steps,
            pending: pending,
            unseen: state.unseen ++ [{index, result_index, event.tool_call_id}]
        }
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

    unless is_map(event.input) or is_nil(event.input) or truncated?(event),
      do: raise(ArgumentError, "tool arguments must be a captured map")

    call = %{
      tool_call_id: "#{event.run_id}:#{event.sequence}",
      function_name: to_string(event.tool_name),
      arguments: event.input || %{},
      extra:
        Map.merge(origin(event), %{native_tool_call_id: event.tool_call_id, outcome: :unknown})
    }

    cond do
      truncated?(event) ->
        diagnostic(state, event, %{uncaptured_tool_arguments: true})

      offered = offered_call(state, event) ->
        steps =
          List.update_at(state.steps, state.response, fn step ->
            Map.update(step, :tool_calls, [call], &(&1 ++ [call]))
          end)

        call_index = length(Enum.at(steps, state.response).tool_calls) - 1

        %{
          state
          | steps: steps,
            offered: List.delete(state.offered, offered),
            pending: Map.put(state.pending, event.tool_call_id, {state.response, call_index})
        }

      true ->
        step = %{
          source: "agent",
          message: "",
          timestamp: event.timestamp,
          llm_call_count: 0,
          tool_calls: [call],
          extra: Map.merge(origin(event), %{outcome: :unknown})
        }

        %{
          state
          | steps: state.steps ++ [step],
            pending: Map.put(state.pending, event.tool_call_id, {length(state.steps), 0})
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

      metadata = event.metadata || %{}
      cache_hit? = get(get(get(metadata, :response), :req_llm), :cache_hit) == true

      step =
        %{
          source: "agent",
          message: response_text(output),
          timestamp: event.timestamp,
          llm_call_count: if(cache_hit?, do: nil, else: 1),
          extra: Map.merge(origin(event), %{model_observation: metadata})
        }
        |> maybe_put(:model_name, model_name(metadata))
        |> maybe_put(
          :reasoning_content,
          reasoning_text(get(get(metadata, :response), :native_reasoning))
        )
        |> maybe_put(:metrics, metrics(metadata))

      %{
        state
        | steps: state.steps ++ [step],
          response: length(state.steps),
          offered: response_calls(output)
      }
    end
  end

  defp project(%Event{kind: :reasoning} = event, state) do
    cond do
      truncated?(event) or is_nil(event.reasoning) ->
        diagnostic(state, event, %{uncaptured_reasoning: true})

      state.response ->
        steps =
          List.update_at(state.steps, state.response, fn step ->
            Map.update!(step, :extra, &Map.put(&1, :next_thought, text(event.reasoning)))
          end)

        %{state | steps: steps}

      true ->
        diagnostic(state, event, %{reasoning: text(event.reasoning)})
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

  # A tool result is shown as the tool message the next request carried, which
  # is what the model read. A result no later request carried keeps the tool's
  # own output and says the model did not see it.
  defp resolve_unseen(state, messages) do
    steps =
      Enum.reduce(state.unseen, state.steps, fn {index, result_index, native_id}, steps ->
        List.update_at(steps, index, fn step ->
          update_in(step, [:observation, :results], fn results ->
            List.update_at(results, result_index, &read_as(&1, tool_message(messages, native_id)))
          end)
        end)
      end)

    %{state | steps: steps, unseen: []}
  end

  defp read_as(result, nil), do: put_in(result, [:extra, :seen_by_model], false)

  defp read_as(result, message) do
    seen = text(get(message, :content))
    result = put_in(result, [:extra, :seen_by_model], true)

    case Map.fetch(result, :content) do
      {:ok, ^seen} -> result
      {:ok, output} -> %{result | content: seen} |> put_in([:extra, :output], output)
      :error -> Map.put(result, :content, seen)
    end
  end

  defp tool_message(messages, native_id) do
    messages
    |> Enum.filter(&(role(&1) == "tool" and native_id in message_call_ids(&1)))
    |> List.last()
  end

  defp message_call_ids(message) do
    ids = message |> get(:tool_calls) |> List.wrap() |> Enum.map(&get(&1, :id))
    Enum.reject([get(message, :tool_call_id) | ids], &is_nil/1)
  end

  defp offered_call(%{response: nil}, _event), do: nil

  defp offered_call(state, event) do
    name = to_string(event.tool_name)

    Enum.find(state.offered, &(&1.id == event.tool_call_id)) ||
      Enum.find(state.offered, &(is_nil(&1.id) and &1.name == name))
  end

  defp response_calls(output) when is_map(output) do
    calls =
      case get(output, :tool_calls) do
        %{} = wrapper -> get(wrapper, :tool_calls)
        calls -> calls
      end

    calls
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn call ->
      id = get(call, :id)
      name = get(call, :name) || get(get(call, :function), :name)
      %{id: id && to_string(id), name: name && to_string(name)}
    end)
  end

  defp response_calls(_output), do: []

  defp response_text(output) when is_binary(output), do: output

  defp response_text(output) when is_map(output) and not is_struct(output) do
    case get(output, :text) || get(output, :content) do
      nil ->
        rest = Map.drop(output, [:tool_calls, "tool_calls"])
        if map_size(rest) == 0, do: "", else: text(rest)

      content ->
        text(content)
    end
  end

  defp response_text(output), do: text(output)

  defp reasoning_text(nil), do: nil
  defp reasoning_text(""), do: nil
  defp reasoning_text(reasoning), do: text(reasoning)

  # A model is named by a string, or by a spec map such as
  # `%{provider: "openai", id: "gpt-x"}`.
  defp model_name(metadata) do
    case get(metadata, :model) do
      nil ->
        nil

      model when is_binary(model) or is_atom(model) ->
        to_string(model)

      %{} = spec ->
        case {get(spec, :provider), get(spec, :id) || get(spec, :model)} do
          {_, nil} -> nil
          {nil, id} -> to_string(id)
          {provider, id} -> "#{provider}:#{id}"
        end

      _other ->
        nil
    end
  end

  defp metrics(metadata) do
    usage = get(metadata, :usage) || %{}
    input = number(get(usage, :input_tokens))
    cached = number(get(usage, :cached_tokens))

    # ATIF counts cached tokens inside the prompt. A provider that reports them
    # apart (`input_includes_cached: false`) has them added back.
    prompt =
      if input && get(usage, :input_includes_cached) == false,
        do: input + (cached || 0) + (number(get(usage, :cache_creation_tokens)) || 0),
        else: input

    %{
      prompt_tokens: prompt,
      completion_tokens: number(get(usage, :output_tokens)),
      cached_tokens: cached,
      cost_usd: number(get(metadata, :cost))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      metrics -> metrics
    end
  end

  defp final_metrics(events, step_count) do
    responses = Enum.filter(events, &(&1.kind == :model_response))
    per_response = Enum.map(responses, &(metrics(&1.metadata || %{}) || %{}))

    totals =
      for {total, key} <- [
            total_prompt_tokens: :prompt_tokens,
            total_completion_tokens: :completion_tokens,
            total_cached_tokens: :cached_tokens,
            total_cost_usd: :cost_usd
          ],
          responses != [],
          Enum.all?(per_response, &Map.has_key?(&1, key)),
          into: %{},
          do: {total, per_response |> Enum.map(& &1[key]) |> Enum.sum()}

    Map.put(totals, :total_steps, step_count)
  end

  defp agent(events) do
    models =
      events
      |> Enum.filter(&(&1.kind == :model_request))
      |> Enum.map(&model_name(&1.metadata))
      |> Enum.uniq()

    tools =
      events
      |> Enum.filter(&(&1.kind == :tools_sent and is_list(&1.input)))
      |> Enum.flat_map(& &1.input)
      |> Enum.uniq()

    %{name: "Imp", version: to_string(Application.spec(:imp, :vsn))}
    |> maybe_put(:model_name, if(match?([_], models), do: hd(models)))
    |> maybe_put(:tool_definitions, if(tools == [], do: nil, else: tools))
  end

  defp context_steps(%Event{input: messages} = event) when is_list(messages) do
    Enum.reduce(messages, [], fn message, steps ->
      case role(message) do
        "tool" -> attach_context_result(steps, message, event)
        _ -> steps ++ [message_step(message, event, true)]
      end
    end)
  end

  defp context_steps(_), do: []

  # Requests grow by appending: the assistant messages are the responses and
  # the tool messages their results, already steps, so only what a request adds
  # from elsewhere becomes a new step.
  defp appended_steps(previous, %Event{input: messages} = event)
       when is_list(previous) and is_list(messages) do
    if Enum.take(messages, length(previous)) == previous do
      messages
      |> Enum.drop(length(previous))
      |> Enum.filter(&(role(&1) in ["user", "system"]))
      |> Enum.map(&message_step(&1, event, false))
    else
      []
    end
  end

  defp appended_steps(_previous, _event), do: []

  defp message_step(message, event, copied?) do
    role = get(message, :role)

    step = %{
      source:
        case role(message) do
          "user" -> "user"
          "assistant" -> "agent"
          _ -> "system"
        end,
      message: text(get(message, :content)),
      timestamp: event.timestamp,
      extra: Map.merge(origin(event), %{context_role: role})
    }

    step = if copied?, do: Map.put(step, :is_copied_context, true), else: step

    if step.source == "agent" do
      calls =
        message
        |> get(:tool_calls)
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map(&context_call/1)

      step
      |> maybe_put(:tool_calls, if(calls == [], do: nil, else: calls))
      |> maybe_put(:reasoning_content, reasoning_text(get(message, :reasoning_content)))
    else
      step
    end
  end

  defp context_call(call) do
    function = get(call, :function) || call
    id = to_string(get(call, :id))

    arguments =
      case get(function, :arguments) do
        arguments when is_map(arguments) ->
          {arguments, nil}

        nil ->
          {%{}, nil}

        raw when is_binary(raw) ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> {decoded, nil}
            _ -> {%{}, raw}
          end

        raw ->
          {%{}, raw}
      end

    {arguments, raw} = arguments

    %{
      tool_call_id: id,
      function_name: to_string(get(function, :name)),
      arguments: arguments,
      extra: maybe_put(%{native_tool_call_id: id}, :raw_arguments, raw)
    }
  end

  defp attach_context_result(steps, message, event) do
    ids = message_call_ids(message)

    index =
      steps
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {step, index} ->
        if Enum.any?(Map.get(step, :tool_calls, []), &(&1.tool_call_id in ids)), do: index
      end)

    case index do
      nil ->
        steps ++ [message_step(message, event, true)]

      index ->
        List.update_at(steps, index, fn step ->
          call = Enum.find(step.tool_calls, &(&1.tool_call_id in ids))
          result = %{source_call_id: call.tool_call_id, content: text(get(message, :content))}
          results = get_in(step, [:observation, :results]) || []
          Map.put(step, :observation, %{results: results ++ [result]})
        end)
    end
  end

  defp role(message), do: message |> get(:role) |> then(&(&1 && to_string(&1)))

  defp put_outcome(map, outcome),
    do: Map.update(map, :extra, %{outcome: outcome}, &Map.put(&1, :outcome, outcome))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp number(value) when is_number(value), do: value
  defp number(_), do: nil

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
