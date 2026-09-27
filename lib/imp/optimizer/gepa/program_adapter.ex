defmodule Imp.Optimizer.GEPA.ProgramAdapter do
  @moduledoc false

  @behaviour Imp.Optimizer.GEPA.Adapter

  alias Imp.Adapter.Types.{ToolCall, ToolCallResults, ToolCalls, ToolResult}
  alias Imp.Optimizer.GEPA.{Candidate, ComponentFeedback, Random, Result}
  alias Imp.Optimizer.TrajectoryRunner

  @enforce_keys [:program, :metric]
  defstruct [
    :program,
    :metric,
    :component_order,
    component_feedback: %{},
    component_tools: %{},
    reflection_record_mode: :beam_native,
    seed: 0,
    max_concurrency: 1,
    timeout: 30_000
  ]

  @type t :: %__MODULE__{
          program: struct(),
          metric: function(),
          component_order: [Candidate.component_name()],
          component_feedback: %{optional(atom()) => ComponentFeedback.callback()},
          component_tools: %{optional(Candidate.component_name()) => [map()]},
          reflection_record_mode: :beam_native | :gepa_v0_1_4,
          seed: non_neg_integer(),
          max_concurrency: pos_integer(),
          timeout: timeout()
        }

  @spec new(struct(), function(), keyword()) :: t()
  def new(program, metric, opts \\ []) do
    component_feedback =
      opts
      |> Keyword.get(:component_feedback)
      |> validate_component_feedback!(program)

    reflection_record_mode = Keyword.get(opts, :reflection_record_mode, :beam_native)

    unless reflection_record_mode in [:beam_native, :gepa_v0_1_4] do
      raise ArgumentError,
            "GEPA reflection record mode must be :beam_native or :gepa_v0_1_4"
    end

    %__MODULE__{
      program: program,
      metric: metric,
      component_order: Enum.map(Imp.ProgramParameters.instruction_components(program), & &1.name),
      component_feedback: component_feedback,
      component_tools: component_tools(program),
      reflection_record_mode: reflection_record_mode,
      seed: Keyword.get(opts, :seed, 0),
      max_concurrency: Keyword.get(opts, :max_concurrency, 1),
      timeout: Keyword.get(opts, :timeout, 30_000)
    }
  end

  @impl true
  def evaluate(%__MODULE__{} = adapter, batch, candidate, opts) do
    program = Candidate.apply_to_program(adapter.program, candidate)

    trajectories =
      TrajectoryRunner.run(program, batch, adapter.metric,
        max_concurrency: adapter.max_concurrency,
        timeout: adapter.timeout,
        deadline: Keyword.get(opts, :deadline),
        metric_trace: Keyword.get(opts, :capture_traces, false),
        runtime: :gepa,
        program_id: candidate_id(candidate)
      )

    case operational_safety_error(trajectories) do
      nil -> :ok
      %Imp.OperationalSafetyError{} = error -> raise error
    end

    scores = Enum.map(trajectories, & &1.score)
    outputs = Enum.map(trajectories, & &1.prediction)
    objective_scores = project_objective_scores(trajectories)
    components = Map.keys(candidate)

    component_trajectories =
      if Keyword.get(opts, :capture_traces, false),
        do: Result.by_component(trajectories, components),
        else: %{}

    killed = Enum.count(trajectories, &Imp.Optimizer.Trajectory.killed?/1)

    Result.new(outputs, scores,
      objective_scores: objective_scores,
      trajectories: component_trajectories,
      side_information: side_information(trajectories, components),
      metadata: %{
        metric_calls: length(trajectories),
        failures: Enum.count(trajectories, &(not is_nil(&1.error))),
        # Killed rows are machinery artifacts (timeout/deadline kills), not
        # model behavior. The engine refuses to cache results that carry any,
        # so a resumed run re-evaluates them instead of replaying deflated
        # scores. The run itself proceeds (matching DSPy, which scores
        # failures 0.0 and continues) - the kills are already loudly logged.
        killed: killed
      }
    )
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{} = adapter, candidate, result, components_to_update) do
    Candidate.validate!(candidate)

    Map.new(components_to_update, fn component ->
      aligned = Map.get(result.trajectories, component, [])

      records =
        aligned
        |> Enum.zip(result.side_information |> Map.get(component, []) |> pad(length(aligned)))
        |> Enum.flat_map(fn
          {%{error: error}, _feedback} when not is_nil(error) ->
            []

          {nil, nil} ->
            []

          {nil, feedback} ->
            if diagnostic_failure?(feedback),
              do: [],
              else: feedback_only_records(feedback, adapter.reflection_record_mode)

          {trajectory, feedback} ->
            case reflected_step(adapter, candidate, trajectory, component) do
              nil ->
                []

              step ->
                feedback = reflective_feedback(adapter, trajectory, component, step, feedback)
                [reflection_record(adapter, trajectory, step, feedback, component)]
            end
        end)

      {component, records}
    end)
  end

  @impl true
  def get_adapter_state(%__MODULE__{reflection_record_mode: mode, component_order: order}) do
    %{
      "reflection_record_mode" => Atom.to_string(mode),
      "component_order" => order
    }
  end

  @impl true
  def set_adapter_state(
        %__MODULE__{reflection_record_mode: :beam_native} = adapter,
        state
      )
      when is_map(state) and map_size(state) == 0 do
    adapter
  end

  def set_adapter_state(
        %__MODULE__{reflection_record_mode: mode, component_order: order} = adapter,
        state
      ) do
    expected = Atom.to_string(mode)

    case state do
      %{"reflection_record_mode" => ^expected, "component_order" => ^order} ->
        adapter

      %{reflection_record_mode: ^mode, component_order: ^order} ->
        adapter

      _ ->
        raise ArgumentError,
              "GEPA resume reflection record mode does not match, or component order differs from the runtime adapter"
    end
  end

  defp side_information(trajectories, components) do
    single_component? = length(components) == 1

    Map.new(components, fn component ->
      feedback =
        Enum.map(trajectories, fn trajectory ->
          cond do
            not is_nil(trajectory.error) ->
              diagnostic_failure(trajectory)

            single_component? or component_visited?(trajectory, component) ->
              trajectory.feedback || metric_feedback(trajectory)

            true ->
              nil
          end
        end)

      {component, feedback}
    end)
  end

  defp component_visited?(%{trace: trace}, component) when is_list(trace) do
    Enum.any?(trace, fn
      %{predictor: ^component} -> true
      _step -> false
    end)
  end

  defp component_visited?(_trajectory, _component), do: false

  defp reflective_feedback(adapter, trajectory, component, step, fallback) do
    case Map.fetch(adapter.component_feedback, component) do
      {:ok, _callback} when step == :unvisited ->
        raise RuntimeError,
              "GEPA component feedback trace is missing predictor #{inspect(component)}"

      {:ok, callback} ->
        ComponentFeedback.feedback!(callback, %ComponentFeedback{
          component: component,
          predictor_inputs: step.inputs,
          predictor_output: step.outputs,
          example: trajectory.example,
          program_output: trajectory.prediction,
          trace: trajectory.trace,
          score: trajectory.score,
          metric_feedback: trajectory.feedback,
          metric_metadata: trajectory.metric_metadata
        })

      :error ->
        fallback
    end
  end

  defp metric_feedback(%{score: score}) when score > 0, do: :successful
  defp metric_feedback(_trajectory), do: :improve

  defp diagnostic_failure(trajectory) do
    %{
      diagnostic_only: true,
      error: trajectory.error,
      example_index: trajectory.index,
      score: trajectory.score
    }
  end

  defp diagnostic_failure?(%{diagnostic_only: true}), do: true
  defp diagnostic_failure?(%{"diagnostic_only" => true}), do: true
  defp diagnostic_failure?(_feedback), do: false

  defp project_objective_scores(trajectories) do
    projected = Enum.map(trajectories, &trajectory_objective_scores/1)

    if Enum.all?(projected, &is_nil/1) do
      nil
    else
      Enum.map(projected, &(&1 || %{}))
    end
  end

  defp trajectory_objective_scores(%{metric_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :objective_scores, Map.get(metadata, "objective_scores")) do
      scores when is_map(scores) -> scores
      _missing_or_invalid -> nil
    end
  end

  defp trajectory_objective_scores(_trajectory), do: nil

  defp validate_component_feedback!(callbacks, program) do
    case ComponentFeedback.validate(callbacks) do
      {:ok, callbacks} ->
        known = program |> Imp.ProgramParameters.instruction_components() |> MapSet.new(& &1.name)
        unknown = callbacks |> Map.keys() |> Enum.reject(&MapSet.member?(known, &1))

        if unknown == [] do
          callbacks
        else
          raise ArgumentError,
                "GEPA component feedback names unknown predictors: #{inspect(unknown)}"
        end

      {:error, message} ->
        raise ArgumentError, "invalid GEPA component feedback: #{message}"
    end
  end

  # The trace step a record reflects on. The BEAM-native record keeps the
  # first call of the predictor beside the whole trace. The pinned record
  # follows DSPy's GEPA adapter, which reflects on one call per example, chosen
  # at random among that predictor's calls when a program calls it more than
  # once (an agent loop calls its step predictor once per turn). Imp's trace
  # holds successful calls only, so DSPy's preference for a call that failed to
  # parse has nothing to choose from; a row whose program failed is left out
  # above. The draw is keyed on the seed, the parent candidate, the component
  # and the example rather than taken from one stream, so it is the same after
  # a resume and under concurrent proposals.
  defp reflected_step(
         %__MODULE__{reflection_record_mode: :beam_native},
         _candidate,
         trajectory,
         component
       ) do
    trajectory.trace |> component_steps(component) |> List.first() || :unvisited
  end

  defp reflected_step(%__MODULE__{} = adapter, candidate, trajectory, component) do
    case component_steps(trajectory.trace, component) do
      [] ->
        nil

      [step] ->
        step

      steps ->
        key = :erlang.phash2({adapter.seed, candidate, component, trajectory.example})
        {index, _state} = Random.integer(length(steps), Random.new(key, :beam_native))
        Enum.at(steps, index)
    end
  end

  defp reflection_record(
         %__MODULE__{reflection_record_mode: :beam_native},
         trajectory,
         _step,
         feedback,
         _component
       ) do
    %{
      "Inputs" => example_inputs(trajectory.example),
      "Generated Outputs" => prediction_output(trajectory.prediction),
      "Feedback" => inspect(feedback || trajectory.feedback || trajectory.error),
      "Score" => trajectory.score,
      "Trace" => trajectory.trace
    }
  end

  defp reflection_record(%__MODULE__{} = adapter, trajectory, step, feedback, component) do
    %{
      "Inputs" =>
        reflection_inputs(
          step.inputs,
          trajectory.prediction,
          Map.get(adapter.component_tools, component, [])
        ),
      "Generated Outputs" => stringify_fields(step.outputs),
      "Feedback" => feedback_text(feedback || trajectory.feedback, trajectory.score)
    }
  end

  defp feedback_only_record(feedback, :beam_native), do: %{"Feedback" => inspect(feedback)}

  defp feedback_only_records(feedback, :beam_native),
    do: [feedback_only_record(feedback, :beam_native)]

  defp feedback_only_records(_feedback, :gepa_v0_1_4), do: []

  defp component_steps(trace, component) when is_list(trace),
    do: Enum.filter(trace, &match?(%{predictor: ^component}, &1))

  defp component_steps(_trace, _component), do: []

  # A predictor's inputs as DSPy's GEPA adapter shows them. A history input is
  # shown as `Context`, one line per turn, and is taken out of the other
  # inputs. The tools the predictor offered the model are shown as `tools`,
  # which is how DSPy's agent loops pass them to their step predictor.
  defp reflection_inputs(inputs, prediction, tools) when is_map(inputs) do
    {histories, others} = Enum.split_with(inputs, fn {_key, value} -> history?(value) end)

    fields = Map.new(others, fn {key, value} -> {to_string(key), text(plain(value))} end)

    fields =
      case histories do
        [] ->
          fields

        [{_key, history}] ->
          Map.put(fields, "Context", context(history, prediction))

        several ->
          raise ArgumentError,
                "GEPA reflection shows one history input as Context, as DSPy's GEPA " <>
                  "does; the predictor was given #{length(several)}: " <>
                  inspect(Enum.map(several, &elem(&1, 0)))
      end

    if tools == [] or Map.has_key?(fields, "tools"),
      do: fields,
      else: Map.put(fields, "tools", text(tools))
  end

  defp reflection_inputs(inputs, _prediction, _tools), do: text(plain(inputs))

  defp history?(%Imp.History{}), do: true
  defp history?(_value), do: false

  defp context(history, prediction) do
    lines =
      history
      |> finished_history(prediction)
      |> Imp.History.messages()
      |> Enum.with_index()
      |> Enum.map_join("", fn {message, index} ->
        # Provider-native reasoning details are opaque continuation data
        # (signatures, encrypted blocks) that tell the reflection model nothing.
        turn = Map.drop(message, [:reasoning_details, "reasoning_details"])
        "  #{index}: #{turn |> plain() |> text()}\n"
      end)

    "```json\n" <> lines <> "```"
  end

  # A step of an agent loop is given the history as it stood when the step
  # ran, since `Imp.History` is a value. DSPy's loops append to one history
  # object that every step holds, so the reflection model reads the whole run,
  # the later tool results and the final answer included, whichever step it
  # reflects on. The finished history is the prediction's `:history` metadata
  # (`Imp.Predict.ReActV2`); when it continues the history this step was given,
  # that continuation is what the reflection model reads.
  defp finished_history(
         %Imp.History{messages: seen} = history,
         %Imp.Prediction{metadata: metadata}
       ) do
    case Map.get(metadata, :history) do
      %Imp.History{messages: finished} ->
        case continuation(finished, seen) do
          nil -> history
          messages -> %{history | messages: messages}
        end

      _none ->
        history
    end
  end

  defp finished_history(history, _prediction), do: history

  defp continuation(finished, seen) when length(finished) < length(seen), do: nil

  defp continuation(finished, seen) do
    if List.starts_with?(finished, seen),
      do: finished,
      else: continuation(tl(finished), seen)
  end

  # The tools a predictor offers its model natively, as name, description and
  # argument properties.
  defp component_tools(program) do
    program
    |> Imp.ProgramParameters.predictors()
    |> Map.new(fn %{name: name, predictor: predictor} -> {name, predictor_tools(predictor)} end)
  end

  defp predictor_tools(%{config: config}) when is_list(config) do
    config
    |> Keyword.get(:tools, [])
    |> List.wrap()
    |> Enum.flat_map(&tool_entry/1)
  end

  defp predictor_tools(_predictor), do: []

  defp tool_entry(%{function: function}), do: tool_entry(function)
  defp tool_entry(%{"function" => function}), do: tool_entry(function)

  defp tool_entry(tool) when is_map(tool) do
    name = Map.get(tool, :name, Map.get(tool, "name"))
    parameters = Map.get(tool, :parameters, Map.get(tool, "parameters")) || %{}

    if name do
      [
        Jason.OrderedObject.new([
          {"name", to_string(name)},
          {"description", Map.get(tool, :description, Map.get(tool, "description"))},
          {"args", Map.get(parameters, "properties", Map.get(parameters, :properties, %{}))}
        ])
      ]
    else
      []
    end
  end

  defp tool_entry(_tool), do: []

  defp stringify_fields(fields) when is_map(fields) do
    Map.new(fields, fn {key, value} -> {to_string(key), text(plain(value))} end)
  end

  defp stringify_fields(value), do: text(plain(value))

  # Imp's own values as the data they hold, so they render as JSON rather than
  # as Elixir terms: a history as its turns, tool calls and results as their
  # fields, and times as ISO 8601. Any other struct is left to
  # `Imp.Adapter.Chat.format_value/1`.
  defp plain(%Imp.History{messages: messages}), do: plain(messages)
  defp plain(%ToolCalls{tool_calls: calls}), do: plain(calls)
  defp plain(%ToolCallResults{tool_call_results: results}), do: plain(results)

  defp plain(%module{} = value) when module in [ToolCall, ToolResult],
    do: value |> Map.from_struct() |> plain()

  defp plain(%module{} = value) when module in [Date, Time, NaiveDateTime, DateTime],
    do: module.to_iso8601(value)

  defp plain(%_{} = struct), do: struct
  defp plain(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, plain(value)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  # DSPy's GEPA gives the reflection model this line when the metric returns
  # a score and no feedback.
  defp feedback_text(feedback, score) when feedback in [nil, :improve, :successful],
    do: "This trajectory got a score of #{text(score)}."

  defp feedback_text(value, _score) when is_binary(value), do: value
  defp feedback_text(value, _score), do: text(plain(value))

  # A value as the reflection model reads it: text as itself, anything else
  # in its JSON spelling (`true`, `null`, `["a"]`), as adapters render values.
  defp text(value), do: Imp.Adapter.Chat.format_value(value)

  defp example_inputs(%Imp.Example{} = example),
    do: example |> Imp.Example.inputs() |> Imp.Example.to_map()

  defp example_inputs(example), do: example

  defp prediction_output(%Imp.Prediction{} = prediction), do: Imp.Prediction.to_map(prediction)
  defp prediction_output(prediction), do: prediction

  defp pad(values, size), do: values ++ List.duplicate(nil, max(size - length(values), 0))

  defp candidate_id(candidate) do
    candidate
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp operational_safety_error(value), do: find_operational_safety(value)

  defp find_operational_safety(%Imp.OperationalSafetyError{} = error), do: error

  defp find_operational_safety(%_{} = struct),
    do: struct |> Map.from_struct() |> find_operational_safety()

  defp find_operational_safety(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find_operational_safety(value) end)
  end

  defp find_operational_safety(list) when is_list(list),
    do: Enum.find_value(list, &find_operational_safety/1)

  defp find_operational_safety(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.find_value(&find_operational_safety/1)

  defp find_operational_safety(_value), do: nil
end
