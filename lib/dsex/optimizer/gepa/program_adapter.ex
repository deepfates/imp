defmodule DSEx.Optimizer.GEPA.ProgramAdapter do
  @moduledoc false

  @behaviour DSEx.Optimizer.GEPA.Adapter

  alias DSEx.Optimizer.GEPA.{Candidate, Result}
  alias DSEx.Optimizer.TrajectoryRunner

  @enforce_keys [:program, :metric]
  defstruct [:program, :metric, max_concurrency: 1, timeout: 30_000]

  @type t :: %__MODULE__{
          program: struct(),
          metric: function(),
          max_concurrency: pos_integer(),
          timeout: timeout()
        }

  @spec new(struct(), function(), keyword()) :: t()
  def new(program, metric, opts \\ []) do
    %__MODULE__{
      program: program,
      metric: metric,
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
        program_id: candidate_id(candidate)
      )

    scores = Enum.map(trajectories, & &1.score)
    outputs = Enum.map(trajectories, & &1.prediction)
    components = Map.keys(candidate)

    component_trajectories =
      if Keyword.get(opts, :capture_traces, false),
        do: Result.by_component(trajectories, components),
        else: %{}

    Result.new(outputs, scores,
      trajectories: component_trajectories,
      side_information: side_information(trajectories, components),
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

  defp side_information(trajectories, components) do
    single_component? = length(components) == 1

    Map.new(components, fn component ->
      feedback =
        Enum.map(trajectories, fn trajectory ->
          cond do
            not is_nil(trajectory.error) ->
              trajectory.error

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

  defp metric_feedback(%{score: score}) when score > 0, do: :successful
  defp metric_feedback(_trajectory), do: :improve

  defp reflection_record(trajectory, feedback) do
    %{
      "Inputs" => example_inputs(trajectory.example),
      "Generated Outputs" => prediction_output(trajectory.prediction),
      "Feedback" => inspect(feedback || trajectory.feedback || trajectory.error),
      "Score" => trajectory.score,
      "Trace" => trajectory.trace
    }
  end

  defp example_inputs(%DSEx.Example{} = example),
    do: example |> DSEx.Example.inputs() |> DSEx.Example.to_map()

  defp example_inputs(example), do: example

  defp prediction_output(%DSEx.Prediction{} = prediction), do: DSEx.Prediction.to_map(prediction)
  defp prediction_output(prediction), do: prediction

  defp pad(values, size), do: values ++ List.duplicate(nil, max(size - length(values), 0))

  defp candidate_id(candidate) do
    candidate
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
