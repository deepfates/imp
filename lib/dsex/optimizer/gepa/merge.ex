defmodule DSEx.Optimizer.GEPA.Merge do
  @moduledoc """
  Deterministic common-ancestor crossover for named GEPA candidates.

  The merge starts from the closest common ancestor. A component changed by
  only one parent is copied from that parent. When both parents changed a
  component differently, the value from the parent with the stronger score on
  their shared, discriminating validation instances is used. Ties favor the
  first parent, making the primitive deterministic without random state.

  `merge/7` evaluates the resulting candidate only on shared instances where
  the parents have different scores. The supplied acceptance callback owns the
  improvement policy; rejected attempts are returned with the same explicit
  lineage as accepted attempts.
  """

  alias DSEx.Optimizer.GEPA.Candidate

  @type attempt_log :: %{
          optional(:ancestors) => [{candidate_id(), candidate_id(), candidate_id()}],
          optional(:descriptions) => [
            {candidate_id(), candidate_id(), [candidate_id() | [candidate_id()]]}
          ]
        }

  @type proposal :: %{
          candidate: Candidate.t(),
          parent_ids: [candidate_id()],
          ancestor: candidate_id(),
          component_sources: map(),
          validation_instances: [validation_id()],
          parent_scores: %{candidate_id() => map()}
        }

  @type candidate_id :: term()
  @type validation_id :: term()
  @type lineage :: %{optional(candidate_id()) => candidate_id() | [candidate_id() | nil] | nil}
  @type candidates :: %{optional(candidate_id()) => Candidate.t()}
  @type validation_scores :: %{
          optional(candidate_id()) => %{optional(validation_id()) => number()}
        }

  @type component_difference :: %{
          ancestor: String.t(),
          left: String.t(),
          right: String.t(),
          left_changed: boolean(),
          right_changed: boolean()
        }

  @type validation_partition :: %{
          left: [validation_id()],
          right: [validation_id()],
          tied: [validation_id()]
        }

  @type merge_lineage :: %{
          operation: :merge,
          parents: [candidate_id()],
          ancestor: candidate_id(),
          component_sources: %{
            optional(Candidate.component_name()) => candidate_id() | [candidate_id()]
          }
        }

  @type outcome :: %{
          status: :accepted | :rejected,
          candidate: Candidate.t(),
          lineage: merge_lineage(),
          validation_instances: [validation_id()],
          evaluation: term(),
          acceptance: term()
        }

  @doc """
  Proposes one source-faithful GEPA v0.1.1 common-ancestor crossover.

  Candidate pairs are sampled from the supplied frontier, unrelated siblings
  are filtered against prior attempts and ancestor quality, and an eligible
  ancestor is sampled by aggregate score. The returned validation sample is
  balanced across left wins, right wins, and ties, as in the upstream merge
  proposer. Evaluation and acceptance remain the engine's responsibility.
  """
  @spec propose_source(
          candidates(),
          lineage(),
          validation_scores(),
          %{optional(candidate_id()) => number()},
          [candidate_id()],
          attempt_log(),
          :rand.state(),
          keyword()
        ) ::
          {:ok, proposal(), attempt_log(), :rand.state()}
          | {:none, attempt_log(), :rand.state()}
  def propose_source(
        candidates,
        lineage,
        validation_scores,
        aggregate_scores,
        frontier_ids,
        attempts,
        rng_state,
        opts \\ []
      ) do
    max_attempts = Keyword.get(opts, :max_attempts, 10)
    overlap_floor = Keyword.get(opts, :overlap_floor, 5)
    sample_size = Keyword.get(opts, :sample_size, 5)
    attempts = Map.merge(%{ancestors: [], descriptions: []}, attempts)

    validate_source_inputs!(
      candidates,
      lineage,
      validation_scores,
      aggregate_scores,
      frontier_ids,
      max_attempts,
      overlap_floor,
      sample_size
    )

    do_propose_source(
      max_attempts,
      candidates,
      lineage,
      validation_scores,
      aggregate_scores,
      frontier_ids,
      attempts,
      rng_state,
      overlap_floor,
      sample_size
    )
  end

  @doc """
  Builds, evaluates, and conditionally accepts a merge of two candidate IDs.

  `evaluator` receives the merged candidate and ordered discriminating
  validation IDs. `acceptance` receives the evaluator result and a context map
  containing the parent scores, candidate, lineage, and validation IDs. It may
  return a boolean, `:accept`, `:reject`, or `{status, detail}`.
  """
  @spec merge(
          candidate_id(),
          candidate_id(),
          candidates(),
          lineage(),
          validation_scores(),
          (Candidate.t(), [validation_id()] -> term()),
          (term(), map() -> boolean() | :accept | :reject | {:accept | :reject, term()})
        ) :: {:accepted | :rejected, outcome()} | {:error, term()}
  def merge(left_id, right_id, candidates, lineage, scores, evaluator, acceptance)
      when is_map(candidates) and is_map(lineage) and is_map(scores) and
             is_function(evaluator, 2) and is_function(acceptance, 2) do
    with :ok <- distinct_parents(left_id, right_id),
         {:ok, left} <- fetch_candidate(candidates, left_id),
         {:ok, right} <- fetch_candidate(candidates, right_id),
         :ok <- unrelated_parents(left_id, right_id, lineage),
         {:ok, ancestor_id} <- common_ancestor(left_id, right_id, lineage),
         {:ok, ancestor} <- fetch_candidate(candidates, ancestor_id),
         {:ok, left_scores} <- fetch_scores(scores, left_id),
         {:ok, right_scores} <- fetch_scores(scores, right_id),
         {:ok, validation_ids} <- discriminating_validation_ids(left_scores, right_scores),
         {:ok, candidate, component_sources} <-
           crossover(left, right, ancestor, left_scores, right_scores,
             left_id: left_id,
             right_id: right_id,
             ancestor_id: ancestor_id
           ) do
      merge_lineage = %{
        operation: :merge,
        parents: [left_id, right_id],
        ancestor: ancestor_id,
        component_sources: component_sources
      }

      context = %{
        candidate: candidate,
        lineage: merge_lineage,
        validation_instances: validation_ids,
        parent_scores: %{
          left_id => Map.take(left_scores, validation_ids),
          right_id => Map.take(right_scores, validation_ids)
        }
      }

      evaluation = evaluator.(candidate, validation_ids)
      decision = acceptance.(evaluation, context)
      {status, acceptance_detail} = normalize_decision!(decision)

      outcome = %{
        status: status,
        candidate: candidate,
        lineage: merge_lineage,
        validation_instances: validation_ids,
        evaluation: evaluation,
        acceptance: acceptance_detail
      }

      {status, outcome}
    end
  end

  @doc "Returns the nearest common ancestor, with stable tie-breaking."
  @spec common_ancestor(candidate_id(), candidate_id(), lineage()) ::
          {:ok, candidate_id()} | {:error, :no_common_ancestor}
  def common_ancestor(left_id, right_id, lineage) when is_map(lineage) do
    left_distances = ancestor_distances(left_id, lineage)
    right_distances = ancestor_distances(right_id, lineage)

    common_ids =
      left_distances
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(right_distances)))

    case Enum.min_by(
           common_ids,
           fn id ->
             left_distance = Map.fetch!(left_distances, id)
             right_distance = Map.fetch!(right_distances, id)
             {max(left_distance, right_distance), left_distance + right_distance, inspect(id)}
           end,
           fn -> nil end
         ) do
      nil -> {:error, :no_common_ancestor}
      ancestor_id -> {:ok, ancestor_id}
    end
  end

  @doc "Describes every component for which either parent differs from the ancestor."
  @spec differing_components(Candidate.t(), Candidate.t(), Candidate.t()) ::
          %{optional(Candidate.component_name()) => component_difference()}
  def differing_components(left, right, ancestor) do
    {left, right, ancestor} = validate_candidate_set!(left, right, ancestor)

    ancestor
    |> stable_keys()
    |> Enum.reduce(%{}, fn component, differences ->
      ancestor_value = Map.fetch!(ancestor, component)
      left_value = Map.fetch!(left, component)
      right_value = Map.fetch!(right, component)

      if left_value == ancestor_value and right_value == ancestor_value do
        differences
      else
        Map.put(differences, component, %{
          ancestor: ancestor_value,
          left: left_value,
          right: right_value,
          left_changed: left_value != ancestor_value,
          right_changed: right_value != ancestor_value
        })
      end
    end)
  end

  @doc "Partitions shared validation IDs according to which parent scored higher."
  @spec validation_partition(map(), map()) :: validation_partition()
  def validation_partition(left_scores, right_scores)
      when is_map(left_scores) and is_map(right_scores) do
    validate_score_map!(left_scores)
    validate_score_map!(right_scores)

    left_scores
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(Map.keys(right_scores)))
    |> Enum.sort_by(&inspect/1)
    |> Enum.reduce(%{left: [], right: [], tied: []}, fn id, partition ->
      bucket =
        cond do
          Map.fetch!(left_scores, id) > Map.fetch!(right_scores, id) -> :left
          Map.fetch!(right_scores, id) > Map.fetch!(left_scores, id) -> :right
          true -> :tied
        end

      Map.update!(partition, bucket, &(&1 ++ [id]))
    end)
  end

  @doc "Returns shared validation IDs on which the two parents have different scores."
  @spec discriminating_validation_ids(map(), map()) ::
          {:ok, [validation_id()]} | {:error, :no_discriminating_validation_instances}
  def discriminating_validation_ids(left_scores, right_scores) do
    partition = validation_partition(left_scores, right_scores)
    ids = partition.left ++ partition.right

    case ids do
      [] -> {:error, :no_discriminating_validation_instances}
      _ -> {:ok, ids}
    end
  end

  @doc "Crosses over component values and reports the source of every value."
  @spec crossover(Candidate.t(), Candidate.t(), Candidate.t(), map(), map(), keyword()) ::
          {:ok, Candidate.t(), map()} | {:error, :no_complementary_component_changes}
  def crossover(left, right, ancestor, left_scores, right_scores, opts \\ [])
      when is_map(left_scores) and is_map(right_scores) and is_list(opts) do
    {left, right, ancestor} = validate_candidate_set!(left, right, ancestor)
    partition = validation_partition(left_scores, right_scores)
    left_id = Keyword.get(opts, :left_id, :left)
    right_id = Keyword.get(opts, :right_id, :right)
    ancestor_id = Keyword.get(opts, :ancestor_id, :ancestor)

    selection = %{
      left_id: left_id,
      right_id: right_id,
      ancestor_id: ancestor_id,
      left_scores: left_scores,
      right_scores: right_scores,
      discriminating_ids: partition.left ++ partition.right
    }

    {candidate, sources, complementary?} =
      ancestor
      |> stable_keys()
      |> Enum.reduce({%{}, %{}, false}, fn component, {candidate, sources, complementary?} ->
        ancestor_value = Map.fetch!(ancestor, component)
        left_value = Map.fetch!(left, component)
        right_value = Map.fetch!(right, component)

        {value, source, contributes?} =
          component_value(ancestor_value, left_value, right_value, selection)

        {Map.put(candidate, component, value), Map.put(sources, component, source),
         complementary? or contributes?}
      end)

    if complementary? do
      {:ok, candidate, sources}
    else
      {:error, :no_complementary_component_changes}
    end
  end

  defp do_propose_source(
         0,
         _candidates,
         _lineage,
         _validation_scores,
         _aggregate_scores,
         _frontier_ids,
         attempts,
         rng_state,
         _overlap_floor,
         _sample_size
       ),
       do: {:none, attempts, rng_state}

  defp do_propose_source(
         remaining,
         candidates,
         lineage,
         validation_scores,
         aggregate_scores,
         frontier_ids,
         attempts,
         rng_state,
         overlap_floor,
         sample_size
       ) do
    with {:ok, [left_id, right_id], rng_state} <- sample_pair(frontier_ids, rng_state),
         :ok <- unrelated_parents(left_id, right_id, lineage),
         eligible when eligible != [] <-
           eligible_ancestors(
             left_id,
             right_id,
             candidates,
             lineage,
             aggregate_scores,
             attempts
           ),
         {ancestor_id, rng_state} <- weighted_choice(eligible, aggregate_scores, rng_state),
         {:ok, candidate, sources, description, rng_state} <-
           source_crossover(
             Map.fetch!(candidates, left_id),
             Map.fetch!(candidates, right_id),
             Map.fetch!(candidates, ancestor_id),
             left_id,
             right_id,
             aggregate_scores,
             rng_state
           ),
         false <- Enum.member?(attempts.descriptions, {left_id, right_id, description}),
         left_scores = Map.fetch!(validation_scores, left_id),
         right_scores = Map.fetch!(validation_scores, right_id),
         true <- validation_overlap(left_scores, right_scores) >= overlap_floor do
      {validation_ids, rng_state} =
        sample_validation_ids(left_scores, right_scores, sample_size, rng_state)

      attempts = %{
        attempts
        | ancestors: attempts.ancestors ++ [{left_id, right_id, ancestor_id}],
          descriptions: attempts.descriptions ++ [{left_id, right_id, description}]
      }

      proposal = %{
        candidate: candidate,
        parent_ids: [left_id, right_id],
        ancestor: ancestor_id,
        component_sources: sources,
        validation_instances: validation_ids,
        parent_scores: %{
          left_id => Map.take(left_scores, validation_ids),
          right_id => Map.take(right_scores, validation_ids)
        }
      }

      {:ok, proposal, attempts, rng_state}
    else
      {:error, :not_enough_candidates} ->
        {:none, attempts, rng_state}

      _reason ->
        do_propose_source(
          remaining - 1,
          candidates,
          lineage,
          validation_scores,
          aggregate_scores,
          frontier_ids,
          attempts,
          rng_state,
          overlap_floor,
          sample_size
        )
    end
  end

  defp eligible_ancestors(
         left_id,
         right_id,
         candidates,
         lineage,
         aggregate_scores,
         attempts
       ) do
    left_ancestors = ancestor_distances(left_id, lineage) |> Map.keys() |> MapSet.new()
    right_ancestors = ancestor_distances(right_id, lineage) |> Map.keys() |> MapSet.new()

    left_ancestors
    |> MapSet.intersection(right_ancestors)
    |> Enum.reject(fn ancestor_id ->
      Enum.member?(attempts.ancestors, {left_id, right_id, ancestor_id}) or
        Map.fetch!(aggregate_scores, ancestor_id) > Map.fetch!(aggregate_scores, left_id) or
        Map.fetch!(aggregate_scores, ancestor_id) > Map.fetch!(aggregate_scores, right_id) or
        not desirable_components?(
          Map.fetch!(candidates, left_id),
          Map.fetch!(candidates, right_id),
          Map.fetch!(candidates, ancestor_id)
        )
    end)
    |> Enum.sort_by(&inspect/1)
  end

  defp desirable_components?(left, right, ancestor) do
    {left, right, ancestor} = validate_candidate_set!(left, right, ancestor)

    Enum.any?(stable_keys(ancestor), fn component ->
      ancestor_value = Map.fetch!(ancestor, component)
      left_value = Map.fetch!(left, component)
      right_value = Map.fetch!(right, component)

      (ancestor_value == left_value or ancestor_value == right_value) and
        left_value != right_value
    end)
  end

  defp source_crossover(
         left,
         right,
         ancestor,
         left_id,
         right_id,
         aggregate_scores,
         rng_state
       ) do
    {left, right, ancestor} = validate_candidate_set!(left, right, ancestor)

    {candidate, sources, description, rng_state} =
      Enum.reduce(
        stable_keys(ancestor),
        {%{}, %{}, [], rng_state},
        fn component, {candidate, sources, description, rng_state} ->
          ancestor_value = Map.fetch!(ancestor, component)
          left_value = Map.fetch!(left, component)
          right_value = Map.fetch!(right, component)

          {value, source, rng_state} =
            source_component_value(
              ancestor_value,
              left_value,
              right_value,
              left_id,
              right_id,
              aggregate_scores,
              rng_state
            )

          {
            Map.put(candidate, component, value),
            Map.put(sources, component, source),
            description ++ [source],
            rng_state
          }
        end
      )

    {:ok, candidate, sources, description, rng_state}
  end

  defp source_component_value(ancestor, left, right, _left_id, right_id, _scores, rng_state)
       when left == ancestor and left != right,
       do: {right, right_id, rng_state}

  defp source_component_value(ancestor, left, right, left_id, _right_id, _scores, rng_state)
       when right == ancestor and left != right,
       do: {left, left_id, rng_state}

  defp source_component_value(_ancestor, value, value, left_id, _right_id, _scores, rng_state),
    do: {value, left_id, rng_state}

  defp source_component_value(
         _ancestor,
         left,
         right,
         left_id,
         right_id,
         scores,
         rng_state
       ) do
    left_score = Map.fetch!(scores, left_id)
    right_score = Map.fetch!(scores, right_id)

    cond do
      left_score > right_score ->
        {left, left_id, rng_state}

      right_score > left_score ->
        {right, right_id, rng_state}

      true ->
        {choice, rng_state} = :rand.uniform_s(2, rng_state)
        if choice == 1, do: {left, left_id, rng_state}, else: {right, right_id, rng_state}
    end
  end

  defp sample_validation_ids(left_scores, right_scores, sample_size, rng_state) do
    partition = validation_partition(left_scores, right_scores)
    each = max(1, ceil(sample_size / 3))

    {selected, rng_state} =
      Enum.reduce([partition.left, partition.right, partition.tied], {[], rng_state}, fn bucket,
                                                                                         {selected,
                                                                                          rng_state} ->
        count = min(length(bucket), min(each, sample_size - length(selected)))
        {sampled, rng_state} = sample_without_replacement(bucket, count, rng_state)
        {selected ++ sampled, rng_state}
      end)

    common_ids =
      left_scores
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Map.keys(right_scores)))
      |> Enum.sort_by(&inspect/1)

    remaining = sample_size - length(selected)
    unused = Enum.reject(common_ids, &Enum.member?(selected, &1))

    {extra, rng_state} =
      sample_without_replacement(unused, min(remaining, length(unused)), rng_state)

    selected = selected ++ extra
    remaining = sample_size - length(selected)
    {repeated, rng_state} = sample_with_replacement(common_ids, remaining, rng_state)
    {selected ++ repeated, rng_state}
  end

  defp sample_pair(ids, _rng_state) when length(ids) < 2,
    do: {:error, :not_enough_candidates}

  defp sample_pair(ids, rng_state) do
    ids = Enum.sort_by(ids, &inspect/1)
    {left, rest, rng_state} = take_random(ids, rng_state)
    {right, _rest, rng_state} = take_random(rest, rng_state)
    {:ok, Enum.sort_by([left, right], &inspect/1), rng_state}
  end

  defp sample_without_replacement(_items, 0, rng_state), do: {[], rng_state}

  defp sample_without_replacement(items, count, rng_state) do
    Enum.reduce(1..count, {[], items, rng_state}, fn _, {selected, remaining, rng_state} ->
      {item, remaining, rng_state} = take_random(remaining, rng_state)
      {selected ++ [item], remaining, rng_state}
    end)
    |> then(fn {selected, _remaining, rng_state} -> {selected, rng_state} end)
  end

  defp sample_with_replacement(_items, 0, rng_state), do: {[], rng_state}

  defp sample_with_replacement(items, count, rng_state) do
    Enum.map_reduce(1..count, rng_state, fn _, rng_state ->
      {index, rng_state} = :rand.uniform_s(length(items), rng_state)
      {Enum.at(items, index - 1), rng_state}
    end)
  end

  defp take_random(items, rng_state) do
    {index, rng_state} = :rand.uniform_s(length(items), rng_state)
    {item, remaining} = List.pop_at(items, index - 1)
    {item, remaining, rng_state}
  end

  defp weighted_choice(ids, scores, rng_state) do
    weights = Enum.map(ids, &(Map.fetch!(scores, &1) |> max(0)))
    total = Enum.sum(weights)

    if total == 0 do
      {index, rng_state} = :rand.uniform_s(length(ids), rng_state)
      {Enum.at(ids, index - 1), rng_state}
    else
      {draw, rng_state} = :rand.uniform_s(rng_state)
      threshold = draw * total

      {chosen, _sum} =
        Enum.zip(ids, weights)
        |> Enum.reduce_while({List.last(ids), 0}, fn {id, weight}, {_chosen, sum} ->
          sum = sum + weight
          if threshold <= sum, do: {:halt, {id, sum}}, else: {:cont, {id, sum}}
        end)

      {chosen, rng_state}
    end
  end

  defp validation_overlap(left_scores, right_scores) do
    left_scores
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(Map.keys(right_scores)))
    |> MapSet.size()
  end

  defp validate_source_inputs!(
         candidates,
         lineage,
         validation_scores,
         aggregate_scores,
         frontier_ids,
         max_attempts,
         overlap_floor,
         sample_size
       ) do
    unless is_map(candidates) and is_map(lineage) and is_map(validation_scores) and
             is_map(aggregate_scores) and is_list(frontier_ids),
           do: raise(ArgumentError, "source merge inputs must be maps plus a frontier id list")

    unless is_integer(max_attempts) and max_attempts > 0,
      do: raise(ArgumentError, ":max_attempts must be a positive integer")

    unless is_integer(overlap_floor) and overlap_floor > 0,
      do: raise(ArgumentError, ":overlap_floor must be a positive integer")

    unless is_integer(sample_size) and sample_size > 0,
      do: raise(ArgumentError, ":sample_size must be a positive integer")

    Enum.each(candidates, fn {_id, candidate} -> Candidate.validate!(candidate) end)
    Enum.each(validation_scores, fn {_id, scores} -> validate_score_map!(scores) end)

    unless Enum.all?(aggregate_scores, fn {_id, score} -> is_number(score) end),
      do: raise(ArgumentError, "aggregate merge scores must be numeric")
  end

  defp component_value(ancestor, left, right, %{ancestor_id: ancestor_id})
       when left == ancestor and right == ancestor,
       do: {ancestor, ancestor_id, false}

  defp component_value(_ancestor, value, value, %{left_id: left_id, right_id: right_id}),
    do: {value, [left_id, right_id], false}

  defp component_value(ancestor, left, right, %{right_id: right_id})
       when left == ancestor,
       do: {right, right_id, true}

  defp component_value(ancestor, left, right, %{left_id: left_id})
       when right == ancestor,
       do: {left, left_id, true}

  defp component_value(_ancestor, left, right, selection) do
    left_total = score_total(selection.left_scores, selection.discriminating_ids)
    right_total = score_total(selection.right_scores, selection.discriminating_ids)

    if right_total > left_total,
      do: {right, selection.right_id, false},
      else: {left, selection.left_id, false}
  end

  defp score_total(scores, ids), do: Enum.reduce(ids, 0, &(Map.fetch!(scores, &1) + &2))

  defp ancestor_distances(candidate_id, lineage) do
    walk_ancestors([{candidate_id, 0}], lineage, %{candidate_id => 0})
    |> Map.delete(candidate_id)
  end

  defp walk_ancestors([], _lineage, distances), do: distances

  defp walk_ancestors([{id, distance} | rest], lineage, distances) do
    {rest, distances} =
      id
      |> parents(lineage)
      |> Enum.reduce({rest, distances}, fn parent, {queue, known} ->
        next_distance = distance + 1

        if Map.get(known, parent, next_distance + 1) <= next_distance do
          {queue, known}
        else
          {queue ++ [{parent, next_distance}], Map.put(known, parent, next_distance)}
        end
      end)

    walk_ancestors(rest, lineage, distances)
  end

  defp parents(id, lineage) do
    case Map.get(lineage, id) do
      nil -> []
      parent when is_list(parent) -> Enum.reject(parent, &is_nil/1)
      parent -> [parent]
    end
  end

  defp unrelated_parents(left_id, right_id, lineage) do
    left_ancestors = ancestor_distances(left_id, lineage)
    right_ancestors = ancestor_distances(right_id, lineage)

    if Map.has_key?(left_ancestors, right_id) or Map.has_key?(right_ancestors, left_id) do
      {:error, :parent_is_ancestor}
    else
      :ok
    end
  end

  defp distinct_parents(id, id), do: {:error, :same_candidate}
  defp distinct_parents(_left_id, _right_id), do: :ok

  defp fetch_candidate(candidates, id) do
    case Map.fetch(candidates, id) do
      {:ok, candidate} -> {:ok, Candidate.validate!(candidate)}
      :error -> {:error, {:unknown_candidate, id}}
    end
  end

  defp fetch_scores(scores, id) do
    case Map.fetch(scores, id) do
      {:ok, score_map} when is_map(score_map) ->
        validate_score_map!(score_map)
        {:ok, score_map}

      {:ok, score_map} ->
        raise ArgumentError,
              "validation scores for #{inspect(id)} must be a map, got: #{inspect(score_map)}"

      :error ->
        {:error, {:missing_validation_scores, id}}
    end
  end

  defp validate_score_map!(scores) do
    unless Enum.all?(scores, fn {_id, score} -> is_number(score) end) do
      raise ArgumentError, "validation score maps must contain only numeric values"
    end

    scores
  end

  defp validate_candidate_set!(left, right, ancestor) do
    left = Candidate.validate!(left)
    right = Candidate.validate!(right)
    ancestor = Candidate.validate!(ancestor)
    component_sets = Enum.map([left, right, ancestor], &(Map.keys(&1) |> MapSet.new()))

    unless Enum.uniq(component_sets) |> length() == 1 do
      raise ArgumentError,
            "merge candidates and their ancestor must have identical component names"
    end

    {left, right, ancestor}
  end

  defp stable_keys(map), do: map |> Map.keys() |> Enum.sort_by(&inspect/1)

  defp normalize_decision!(true), do: {:accepted, true}
  defp normalize_decision!(:accept), do: {:accepted, :accept}
  defp normalize_decision!({:accept, detail}), do: {:accepted, detail}
  defp normalize_decision!(false), do: {:rejected, false}
  defp normalize_decision!(:reject), do: {:rejected, :reject}
  defp normalize_decision!({:reject, detail}), do: {:rejected, detail}

  defp normalize_decision!(decision) do
    raise ArgumentError,
          "merge acceptance callback must return a boolean, :accept, :reject, " <>
            "{:accept, detail}, or {:reject, detail}; got: #{inspect(decision)}"
  end
end
