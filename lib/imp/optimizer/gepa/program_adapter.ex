defmodule Imp.Optimizer.GEPA.ProgramAdapter do
  @moduledoc false

  @behaviour Imp.Optimizer.GEPA.Adapter

  alias Imp.Optimizer.GEPA.{Candidate, ComponentFeedback, Result}
  alias Imp.Optimizer.TrajectoryRunner

  @enforce_keys [:program, :metric]
  defstruct [:program, :metric, component_feedback: %{}, max_concurrency: 1, timeout: 30_000]

  @type t :: %__MODULE__{
          program: struct(),
          metric: function(),
          component_feedback: %{optional(atom()) => ComponentFeedback.callback()},
          max_concurrency: pos_integer(),
          timeout: timeout()
        }

  @spec new(struct(), function(), keyword()) :: t()
  def new(program, metric, opts \\ []) do
    component_feedback =
      opts
      |> Keyword.get(:component_feedback)
      |> validate_component_feedback!(program)

    %__MODULE__{
      program: program,
      metric: metric,
      component_feedback: component_feedback,
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
        runtime: :gepa,
        program_id: candidate_id(candidate)
      )

    scores = Enum.map(trajectories, & &1.score)
    outputs = Enum.map(trajectories, & &1.prediction)
    objective_scores = project_objective_scores(trajectories)
    components = Map.keys(candidate)

    component_trajectories =
      if Keyword.get(opts, :capture_traces, false),
        do: Result.by_component(trajectories, components),
        else: %{}

    Result.new(outputs, scores,
      objective_scores: objective_scores,
      trajectories: component_trajectories,
      side_information:
        side_information(
          trajectories,
          components,
          adapter.component_feedback,
          Keyword.get(opts, :capture_traces, false)
        ),
      metadata: %{
        metric_calls: length(trajectories),
        failures: Enum.count(trajectories, &(not is_nil(&1.error)))
      }
    )
  end

  @impl true
  def make_reflective_dataset(%__MODULE__{}, candidate, result, components_to_update) do
    Candidate.validate!(candidate)

    Map.new(components_to_update, fn component ->
      aligned = Map.get(result.trajectories, component, [])

      records =
        aligned
        |> Enum.zip(result.side_information |> Map.get(component, []) |> pad(length(aligned)))
        |> Enum.flat_map(fn
          {nil, nil} -> []
          {nil, feedback} -> [%{"Feedback" => inspect(feedback)}]
          {trajectory, feedback} -> [reflection_record(trajectory, feedback)]
        end)

      {component, records}
    end)
  end

  defp side_information(trajectories, components, callbacks, capture_traces?) do
    single_component? = length(components) == 1

    Map.new(components, fn component ->
      feedback =
        Enum.map(trajectories, fn trajectory ->
          cond do
            not is_nil(trajectory.error) ->
              trajectory.error

            single_component? or component_visited?(trajectory, component) ->
              component_feedback(
                trajectory,
                component,
                callbacks,
                capture_traces?
              )

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

  defp component_feedback(trajectory, component, callbacks, true) do
    case Map.fetch(callbacks, component) do
      {:ok, callback} ->
        step = fetch_component_step!(trajectory.trace, component)

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
        trajectory.feedback || metric_feedback(trajectory)
    end
  end

  defp component_feedback(trajectory, _component, _callbacks, _capture_traces?),
    do: trajectory.feedback || metric_feedback(trajectory)

  defp fetch_component_step!(trace, component) do
    Enum.find(trace, &match?(%{predictor: ^component}, &1)) ||
      raise RuntimeError,
            "GEPA component feedback trace is missing predictor #{inspect(component)}"
  end

  defp metric_feedback(%{score: score}) when score > 0, do: :successful
  defp metric_feedback(_trajectory), do: :improve

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
        known = program |> Imp.ProgramParameters.predictors() |> MapSet.new(& &1.name)
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

  defp reflection_record(trajectory, feedback) do
    %{
      "Inputs" => example_inputs(trajectory.example),
      "Generated Outputs" => prediction_output(trajectory.prediction),
      "Feedback" => inspect(feedback || trajectory.feedback || trajectory.error),
      "Score" => trajectory.score,
      "Trace" => trajectory.trace
    }
  end

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
end
