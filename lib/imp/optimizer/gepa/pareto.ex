defmodule Imp.Optimizer.GEPA.Pareto do
  @moduledoc "Winner-set mapping, pruning, and sampling for GEPA frontiers."

  alias Imp.Optimizer.GEPA.Random
  alias Imp.Optimizer.MIPROv2.PythonRandom

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

    dominated = remove_until_stable(programs, mapping, %{})
    dominators = MapSet.difference(MapSet.new(programs), MapSet.new(Map.keys(dominated)))

    Map.new(mapping, fn {key, front} -> {key, MapSet.intersection(front, dominators)} end)
  end

  @doc "Samples a source-faithful Pareto candidate in proportion to winner-set coverage."
  @spec sample(mapping(), %{optional(candidate_id()) => number()}, Random.state()) ::
          {candidate_id(), Random.state()}
  def sample(mapping, aggregate_scores, rng_state) do
    sampling_list =
      mapping
      |> remove_dominated(aggregate_scores)
      |> sampling_list(rng_state)

    case sampling_list do
      [] ->
        raise ArgumentError, "cannot sample from an empty GEPA Pareto frontier"

      candidates ->
        {position, rng_state} = Random.integer(length(candidates), rng_state)
        {Enum.at(candidates, position), rng_state}
    end
  end

  # Pinned GEPA builds a frequency dictionary by walking validation IDs in
  # loader order, then expands candidates in first-seen dictionary order.
  # The sealed comparator uses integer validation IDs and candidate indexes,
  # for which Erlang term ordering exactly reconstructs that Python order.
  defp sampling_list(mapping, %PythonRandom{}) do
    {order, frequencies} =
      mapping
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], %{}}, fn {_key, front}, {order, frequencies} ->
        front
        |> Enum.sort()
        |> Enum.reduce({order, frequencies}, fn candidate, {order, frequencies} ->
          order = if Map.has_key?(frequencies, candidate), do: order, else: order ++ [candidate]
          {order, Map.update(frequencies, candidate, 1, &(&1 + 1))}
        end)
      end)

    Enum.flat_map(order, &List.duplicate(&1, Map.fetch!(frequencies, &1)))
  end

  defp sampling_list(mapping, _beam_rng) do
    mapping
    |> Enum.sort_by(fn {key, _front} -> inspect(key) end)
    |> Enum.flat_map(fn {_key, front} -> front |> Enum.sort_by(&inspect/1) end)
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
           not Map.has_key?(dominated, candidate) and
             dominated?(candidate, programs, mapping, dominated)
         end) do
      nil -> dominated
      candidate -> remove_until_stable(programs, mapping, Map.put(dominated, candidate, true))
    end
  end

  defp dominated?(candidate, programs, mapping, dominated) do
    remaining =
      programs
      |> MapSet.new()
      |> MapSet.delete(candidate)
      |> MapSet.difference(MapSet.new(Map.keys(dominated)))

    mapping
    |> Map.values()
    |> Enum.filter(&MapSet.member?(&1, candidate))
    |> Enum.all?(fn front -> not MapSet.disjoint?(front, remaining) end)
  end
end
