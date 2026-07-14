defmodule Imp.Optimizer.GEPA.Result do
  @moduledoc """
  Result of evaluating a named GEPA candidate on an ordered batch.

  Outputs, scores, and objective scores are aligned by example. Component
  trajectories are also batch-aligned and reuse `Imp.Optimizer.Trajectory`;
  `nil` marks an example where that component did not execute. Actionable side
  information is keyed by the component that can act on it.
  """

  alias Imp.Optimizer.GEPA.Candidate
  alias Imp.Optimizer.Trajectory

  @type objective_scores :: %{optional(atom() | String.t()) => number()}
  @type trajectory :: struct()
  @type component_trajectories :: %{
          optional(Candidate.component_name()) => [trajectory() | nil]
        }
  @type side_information :: %{optional(Candidate.component_name()) => [term()]}

  @enforce_keys [:outputs, :aggregate_score, :scores]
  defstruct outputs: [],
            aggregate_score: 0.0,
            scores: [],
            objective_scores: nil,
            trajectories: %{},
            side_information: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          outputs: [term()],
          aggregate_score: float(),
          scores: [number()],
          objective_scores: [objective_scores()] | nil,
          trajectories: component_trajectories(),
          side_information: side_information(),
          metadata: map()
        }

  @doc "Builds a result and derives its aggregate score as the mean example score."
  @spec new([term()], [number()], keyword()) :: t()
  def new(outputs, scores, opts \\ []) when is_list(outputs) and is_list(scores) do
    %__MODULE__{
      outputs: outputs,
      aggregate_score: average(scores),
      scores: scores,
      objective_scores: Keyword.get(opts, :objective_scores),
      trajectories: Keyword.get(opts, :trajectories, %{}),
      side_information: Keyword.get(opts, :side_information, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Indexes existing execution trajectories by the named components they visited."
  @spec by_component([trajectory()], [Candidate.component_name()]) :: component_trajectories()
  def by_component(trajectories, component_names) when is_list(trajectories) do
    Map.new(component_names, fn name ->
      {name, Enum.map(trajectories, &for_component(&1, name))}
    end)
  end

  @doc false
  @spec validate!(t(), non_neg_integer(), Candidate.t(), boolean()) :: t()
  def validate!(%__MODULE__{} = result, batch_size, candidate, capture_traces)
      when is_integer(batch_size) and batch_size >= 0 and is_boolean(capture_traces) do
    candidate = Candidate.validate!(candidate)
    component_names = Map.keys(candidate) |> MapSet.new()

    validate_aligned!(:outputs, result.outputs, batch_size)
    validate_scores!(result.scores, batch_size)
    validate_aggregate!(result)
    validate_objective_scores!(result.objective_scores, batch_size)
    validate_trajectories!(result.trajectories, component_names, batch_size, capture_traces)
    validate_side_information!(result.side_information, component_names)
    validate_metadata!(result.metadata)

    result
  end

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp trace_component(%{predictor: name}), do: name
  defp trace_component(_step), do: nil

  defp for_component(%Trajectory{trace: trace} = trajectory, name) when is_list(trace) do
    if Enum.any?(trace, &(trace_component(&1) == name)), do: trajectory
  end

  defp for_component(%Trajectory{}, _name), do: nil

  defp validate_aligned!(field, values, batch_size) when is_list(values) do
    if length(values) != batch_size do
      raise ArgumentError,
            "GEPA result #{field} must contain #{batch_size} entries, got: #{length(values)}"
    end
  end

  defp validate_aligned!(field, values, _batch_size) do
    raise ArgumentError, "GEPA result #{field} must be a list, got: #{inspect(values)}"
  end

  defp validate_scores!(scores, batch_size) do
    validate_aligned!(:scores, scores, batch_size)

    unless Enum.all?(scores, &is_number/1) do
      raise ArgumentError, "GEPA result scores must all be numeric"
    end
  end

  defp validate_aggregate!(%__MODULE__{aggregate_score: aggregate, scores: scores}) do
    unless is_number(aggregate) and aggregate == average(scores) do
      raise ArgumentError, "GEPA aggregate score must equal the mean per-example score"
    end
  end

  defp validate_objective_scores!(nil, _batch_size), do: :ok

  defp validate_objective_scores!(objective_scores, batch_size) do
    validate_aligned!(:objective_scores, objective_scores, batch_size)

    unless Enum.all?(objective_scores, &valid_objective_scores?/1) do
      raise ArgumentError, "GEPA objective scores must be maps with numeric values"
    end
  end

  defp valid_objective_scores?(scores) when is_map(scores) do
    Enum.all?(scores, fn {name, score} ->
      (is_atom(name) or is_binary(name)) and is_number(score)
    end)
  end

  defp valid_objective_scores?(_scores), do: false

  defp validate_trajectories!(trajectories, component_names, batch_size, capture_traces)
       when is_map(trajectories) do
    trajectory_names = Map.keys(trajectories) |> MapSet.new()

    if capture_traces and trajectory_names != component_names do
      raise ArgumentError, "captured GEPA trajectories must cover every candidate component"
    end

    unless MapSet.subset?(trajectory_names, component_names) do
      raise ArgumentError, "GEPA trajectories contain an unknown component"
    end

    Enum.each(trajectories, fn {name, aligned} ->
      validate_aligned!("trajectories for #{inspect(name)}", aligned, batch_size)

      unless Enum.all?(aligned, &(is_nil(&1) or match?(%Trajectory{}, &1))) do
        raise ArgumentError, "GEPA component trajectories must reuse Imp.Optimizer.Trajectory"
      end
    end)
  end

  defp validate_trajectories!(trajectories, _names, _size, _capture) do
    raise ArgumentError, "GEPA result trajectories must be a map, got: #{inspect(trajectories)}"
  end

  defp validate_side_information!(side_information, component_names)
       when is_map(side_information) do
    side_information_names = Map.keys(side_information) |> MapSet.new()

    unless MapSet.subset?(side_information_names, component_names) and
             Enum.all?(side_information, fn {_name, information} -> is_list(information) end) do
      raise ArgumentError,
            "GEPA side information must contain lists keyed by candidate component"
    end
  end

  defp validate_side_information!(side_information, _component_names) do
    raise ArgumentError,
          "GEPA result side information must be a map, got: #{inspect(side_information)}"
  end

  defp validate_metadata!(metadata) when is_map(metadata), do: :ok

  defp validate_metadata!(metadata) do
    raise ArgumentError, "GEPA result metadata must be a map, got: #{inspect(metadata)}"
  end
end
