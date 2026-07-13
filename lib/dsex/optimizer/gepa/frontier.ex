defmodule DSEx.Optimizer.GEPA.Frontier do
  @moduledoc """
  Pure policy for constructing GEPA candidate frontiers from validation results.

  The four policies follow the frontier shapes in GEPA v0.1.1:

    * `:instance` tracks the primary metric (`Result.scores`) per example.
    * `:objective` tracks each objective's mean across the examples that report it.
    * `:hybrid` combines the aggregate and objective dimensions.
    * `:cartesian` tracks every reported `{example, objective}` pair independently.

  Keys are tagged so example indexes and objective names cannot collide. Winner
  coverage, redundant-candidate removal, and weighted sampling are delegated to
  `DSEx.Optimizer.GEPA.Pareto`.
  """

  alias DSEx.Optimizer.GEPA.{Pareto, Result}

  @policies [:instance, :objective, :hybrid, :cartesian]

  @type policy :: :instance | :objective | :hybrid | :cartesian
  @type candidate_id :: term()
  @type candidate_result :: {candidate_id(), Result.t()}

  @doc "Returns the per-dimension winner mapping for a frontier policy."
  @spec mapping([candidate_result()], policy()) :: Pareto.mapping()
  def mapping(candidates, policy) when is_list(candidates) do
    validate_policy!(policy)
    validate_candidates!(candidates, policy)

    candidates
    |> Enum.map(fn {candidate_id, result} ->
      {candidate_id, dimensions(result, policy)}
    end)
    |> Pareto.winner_mapping()
  end

  def mapping(candidates, _policy) do
    raise ArgumentError,
          "GEPA frontier candidates must be a list of {candidate_id, result} tuples, got: " <>
            inspect(candidates)
  end

  @doc "Returns the deterministic set of non-redundant frontier candidate IDs."
  @spec candidate_ids([candidate_result()], policy()) :: [candidate_id()]
  def candidate_ids(candidates, policy) when is_list(candidates) do
    candidates
    |> mapping(policy)
    |> Pareto.candidate_ids(aggregate_scores(candidates))
  end

  def candidate_ids(candidates, policy),
    do: candidates |> mapping(policy) |> Pareto.candidate_ids()

  @doc "Samples a frontier candidate in proportion to its surviving winner coverage."
  @spec sample([candidate_result()], policy(), :rand.state()) :: {candidate_id(), :rand.state()}
  def sample(candidates, policy, rng_state) when is_list(candidates) do
    candidates
    |> mapping(policy)
    |> Pareto.sample(aggregate_scores(candidates), rng_state)
  end

  def sample(candidates, policy, rng_state) do
    candidates |> mapping(policy) |> Pareto.sample(%{}, rng_state)
  end

  defp dimensions(%Result{} = result, :instance), do: instance_dimensions(result)
  defp dimensions(%Result{} = result, :objective), do: objective_dimensions(result)

  defp dimensions(%Result{} = result, :hybrid) do
    Map.merge(instance_dimensions(result), objective_dimensions(result))
  end

  defp dimensions(%Result{} = result, :cartesian) do
    result.objective_scores
    |> Enum.zip(validation_ids(result))
    |> Enum.reduce(%{}, fn {scores, example_id}, dimensions ->
      Enum.reduce(scores, dimensions, fn {objective, score}, dimensions ->
        Map.put(dimensions, {:cartesian, example_id, objective}, score)
      end)
    end)
  end

  defp instance_dimensions(%Result{scores: scores} = result) do
    scores
    |> Enum.zip(validation_ids(result))
    |> Map.new(fn {score, example_id} -> {{:instance, example_id}, score} end)
  end

  defp validation_ids(%Result{scores: scores, metadata: metadata}) do
    Map.get(
      metadata,
      :validation_ids,
      Map.get(metadata, "validation_ids", indexes(length(scores)))
    )
  end

  defp indexes(0), do: []
  defp indexes(size), do: Enum.to_list(0..(size - 1))

  defp objective_dimensions(%Result{objective_scores: objective_scores}) do
    objective_scores
    |> Enum.reduce(%{}, &merge_objective_scores/2)
    |> Map.new(fn {objective, {total, count}} ->
      {{:objective, objective}, total / count}
    end)
  end

  defp merge_objective_scores(scores, grouped) do
    Enum.reduce(scores, grouped, fn {objective, score}, grouped ->
      Map.update(grouped, objective, {score, 1}, fn {total, count} ->
        {total + score, count + 1}
      end)
    end)
  end

  defp aggregate_scores(candidates) do
    Map.new(candidates, fn {candidate_id, %Result{aggregate_score: score}} ->
      {candidate_id, score}
    end)
  end

  defp validate_policy!(policy) when policy in @policies, do: :ok

  defp validate_policy!(policy) do
    raise ArgumentError,
          "GEPA frontier policy must be one of #{inspect(@policies)}, got: #{inspect(policy)}"
  end

  defp validate_candidates!(candidates, policy) do
    Enum.each(candidates, &validate_candidate!/1)
    validate_unique_ids!(candidates)
    validate_score_alignment!(candidates)

    if policy in [:objective, :hybrid, :cartesian] do
      Enum.each(candidates, &validate_objectives!/1)
    end
  end

  defp validate_candidate!({candidate_id, %Result{} = result}) do
    unless is_list(result.scores) and Enum.all?(result.scores, &is_number/1) do
      raise ArgumentError,
            "GEPA frontier candidate #{inspect(candidate_id)} must have a numeric scores list"
    end

    unless is_number(result.aggregate_score) do
      raise ArgumentError,
            "GEPA frontier candidate #{inspect(candidate_id)} must have a numeric aggregate score"
    end
  end

  defp validate_candidate!(candidate) do
    raise ArgumentError,
          "GEPA frontier candidates must be {candidate_id, %Result{}} tuples, got: " <>
            inspect(candidate)
  end

  defp validate_unique_ids!(candidates) do
    ids = Enum.map(candidates, &elem(&1, 0))

    if MapSet.size(MapSet.new(ids)) != length(ids) do
      raise ArgumentError, "GEPA frontier candidate IDs must be unique"
    end
  end

  defp validate_score_alignment!([]), do: :ok

  defp validate_score_alignment!([{_candidate_id, first} | rest]) do
    expected = length(first.scores)

    case Enum.find(rest, fn {_candidate_id, result} -> length(result.scores) != expected end) do
      nil ->
        :ok

      {candidate_id, result} ->
        raise ArgumentError,
              "GEPA frontier candidate #{inspect(candidate_id)} has #{length(result.scores)} scores; " <>
                "expected #{expected}"
    end
  end

  defp validate_objectives!({candidate_id, %Result{objective_scores: nil}}) do
    raise ArgumentError,
          "GEPA frontier policy requires objective scores for candidate #{inspect(candidate_id)}"
  end

  defp validate_objectives!({candidate_id, %Result{} = result}) do
    objective_scores = result.objective_scores

    unless is_list(objective_scores) and length(objective_scores) == length(result.scores) do
      raise ArgumentError,
            "GEPA frontier candidate #{inspect(candidate_id)} objective scores must align with its scores"
    end

    unless Enum.all?(objective_scores, &valid_objective_scores?/1) do
      raise ArgumentError,
            "GEPA frontier candidate #{inspect(candidate_id)} objective scores must be maps with " <>
              "atom or string names and numeric values"
    end

    if Enum.all?(objective_scores, &(map_size(&1) == 0)) do
      raise ArgumentError,
            "GEPA frontier candidate #{inspect(candidate_id)} must report at least one objective"
    end
  end

  defp valid_objective_scores?(scores) when is_map(scores) do
    Enum.all?(scores, fn {name, score} ->
      (is_atom(name) or is_binary(name)) and is_number(score)
    end)
  end

  defp valid_objective_scores?(_scores), do: false
end
