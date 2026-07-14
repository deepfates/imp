defmodule Imp.Optimizer.GEPA.Pareto do
  @moduledoc "Winner-set mapping, pruning, and sampling for GEPA frontiers."

  @type candidate_id :: term()
  @type frontier_key :: term()
  @type mapping :: %{optional(frontier_key()) => MapSet.t(candidate_id())}

  @spec winner_mapping([{candidate_id(), %{optional(frontier_key()) => number()}}]) :: mapping()
  def winner_mapping(candidates) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn {_candidate_id, scores} -> Map.keys(scores) end)
    |> MapSet.new()
    |> Enum.into(%{}, fn key ->
      scored =
        for {candidate_id, scores} <- candidates,
            {:ok, score} <- [Map.fetch(scores, key)],
            do: {candidate_id, score}

      best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

      winners =
        scored
        |> Enum.filter(fn {_candidate_id, score} -> score == best end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      {key, winners}
    end)
  end

  @doc "Removes candidates whose instance-front coverage is redundant."
  @spec remove_dominated(mapping(), %{optional(candidate_id()) => number()}) :: mapping()
  def remove_dominated(mapping, aggregate_scores \\ %{}) when is_map(mapping) do
    programs =
      mapping
      |> Map.values()
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      |> Enum.sort_by(&{Map.get(aggregate_scores, &1, 1), inspect(&1)})

    dominated = remove_until_stable(programs, mapping, MapSet.new())
    dominators = MapSet.difference(MapSet.new(programs), dominated)

    Map.new(mapping, fn {key, front} -> {key, MapSet.intersection(front, dominators)} end)
  end

  @doc "Samples a source-faithful Pareto candidate in proportion to winner-set coverage."
  @spec sample(mapping(), %{optional(candidate_id()) => number()}, :rand.state()) ::
          {candidate_id(), :rand.state()}
  def sample(mapping, aggregate_scores, rng_state) do
    sampling_list =
      mapping
      |> remove_dominated(aggregate_scores)
      |> Enum.sort_by(fn {key, _front} -> inspect(key) end)
      |> Enum.flat_map(fn {_key, front} -> front |> Enum.sort_by(&inspect/1) end)

    case sampling_list do
      [] ->
        raise ArgumentError, "cannot sample from an empty GEPA Pareto frontier"

      candidates ->
        {position, rng_state} = :rand.uniform_s(length(candidates), rng_state)
        {Enum.at(candidates, position - 1), rng_state}
    end
  end

  @spec candidate_ids(mapping(), %{optional(candidate_id()) => number()}) :: [candidate_id()]
  def candidate_ids(mapping, aggregate_scores \\ %{}) do
    mapping
    |> remove_dominated(aggregate_scores)
    |> Map.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> Enum.sort_by(&inspect/1)
  end

  defp remove_until_stable(programs, mapping, dominated) do
    case Enum.find(programs, fn candidate ->
           not MapSet.member?(dominated, candidate) and
             dominated?(candidate, programs, mapping, dominated)
         end) do
      nil -> dominated
      candidate -> remove_until_stable(programs, mapping, MapSet.put(dominated, candidate))
    end
  end

  defp dominated?(candidate, programs, mapping, dominated) do
    remaining =
      programs |> MapSet.new() |> MapSet.delete(candidate) |> MapSet.difference(dominated)

    mapping
    |> Map.values()
    |> Enum.filter(&MapSet.member?(&1, candidate))
    |> Enum.all?(fn front -> not MapSet.disjoint?(front, remaining) end)
  end
end
