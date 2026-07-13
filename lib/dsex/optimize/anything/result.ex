defmodule DSEx.Optimize.Anything.Result do
  @moduledoc """
  Immutable Optimize Anything result projected from the GEPA engine.

  The result keeps the complete named candidate population, lineage,
  validation scores, Pareto winners, observed budget, and a JSON-safe engine
  checkpoint. Binary candidates are wrapped internally and unwrapped only by
  `best_candidate/1`.
  """

  alias DSEx.Optimizer.GEPA.{Engine, Frontier}
  alias DSEx.Optimizer.Report, as: OptimizerReport

  @schema_version 2

  @enforce_keys [
    :candidates,
    :parents,
    :validation_scores,
    :validation_subscores,
    :instance_frontier,
    :discovery_evaluation_counts,
    :checkpoint
  ]
  defstruct candidates: [],
            parents: [],
            validation_scores: [],
            validation_subscores: [],
            candidate_side_information: [],
            best_outputs_valset: nil,
            instance_frontier: %{},
            objective_scores: nil,
            objective_frontier: nil,
            discovery_evaluation_counts: [],
            total_metric_calls: 0,
            full_evaluations: 0,
            reflection_calls: 0,
            mode: nil,
            run_dir: nil,
            seed: 0,
            stop_reason: nil,
            rejected: [],
            history: [],
            string_candidate_key: nil,
            checkpoint: %{}

  @type t :: %__MODULE__{}

  @doc "Builds an immutable public result from a completed GEPA engine state."
  @spec from_state(struct(), keyword()) :: t()
  def from_state(%Engine.State{} = state, opts \\ []) do
    candidate_results = Enum.map(state.candidates, &{&1.id, &1.validation})

    %__MODULE__{
      candidates: Enum.map(state.candidates, & &1.candidate),
      parents: Enum.map(state.candidates, & &1.parent_ids),
      validation_scores: Enum.map(state.candidates, & &1.validation.aggregate_score),
      validation_subscores: Enum.map(state.candidates, &validation_subscores/1),
      candidate_side_information: Enum.map(state.candidates, & &1.validation.side_information),
      best_outputs_valset: state.best_outputs_valset,
      instance_frontier: frontier(candidate_results, :instance),
      objective_scores: aggregate_objective_scores(state.candidates),
      objective_frontier: optional_frontier(candidate_results, :objective),
      discovery_evaluation_counts: Enum.map(state.candidates, & &1.discovered_at),
      total_metric_calls: state.budget.metric_calls,
      full_evaluations: state.budget.full_evaluations,
      reflection_calls: state.budget.reflection_calls,
      mode: Keyword.get(opts, :mode),
      run_dir: Keyword.get(opts, :run_dir),
      seed: Keyword.get(opts, :seed, 0),
      stop_reason: state.stop_reason,
      rejected: state.rejected,
      history: state.history,
      string_candidate_key: Keyword.get(opts, :string_candidate_key),
      checkpoint: Engine.dump_state(state)
    }
  end

  @doc "Returns the first candidate with the maximum aggregate validation score."
  @spec best_index(t()) :: non_neg_integer()
  def best_index(%__MODULE__{validation_scores: []}) do
    raise ArgumentError, "Optimize Anything result has no candidates"
  end

  def best_index(%__MODULE__{validation_scores: scores}) do
    scores
    |> Enum.with_index()
    |> Enum.max_by(fn {score, _index} -> score end, fn -> nil end)
    |> elem(1)
  end

  @doc "Returns the best named candidate, or a binary for string-candidate runs."
  @spec best_candidate(t()) :: map() | String.t()
  def best_candidate(%__MODULE__{} = result) do
    candidate = Enum.fetch!(result.candidates, best_index(result))

    case result.string_candidate_key do
      nil -> candidate
      key -> Map.fetch!(candidate, key)
    end
  end

  @doc "Returns the winning co-evolved refiner prompt when present."
  @spec best_refiner_prompt(t()) :: String.t() | nil
  def best_refiner_prompt(%__MODULE__{} = result) do
    candidate = Enum.fetch!(result.candidates, best_index(result))
    Map.get(candidate, :refiner_prompt, Map.get(candidate, "refiner_prompt"))
  end

  @doc "Converts the result to a JSON-safe schema-versioned map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    result
    |> Map.from_struct()
    |> Map.update!(:instance_frontier, &dump_frontier/1)
    |> Map.update!(:objective_frontier, &dump_frontier/1)
    |> Map.put(:validation_schema_version, @schema_version)
    |> OptimizerReport.json_safe()
  end

  @doc "Restores a version-2 Optimize Anything result."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    map = OptimizerReport.restore_json_safe(map)
    version = fetch(map, :validation_schema_version, 0)

    if version != @schema_version do
      raise ArgumentError,
            "unsupported Optimize Anything result schema #{inspect(version)}; expected #{@schema_version}"
    end

    fields = __struct__() |> Map.from_struct() |> Map.keys()
    values = Map.new(fields, &{&1, fetch(map, &1, Map.fetch!(__struct__(), &1))})

    values =
      values
      |> Map.update!(:instance_frontier, &load_frontier/1)
      |> Map.update!(:objective_frontier, &load_frontier/1)

    struct!(__MODULE__, values)
  end

  def from_map(value) do
    raise ArgumentError, "Optimize Anything result must be a map, got: #{inspect(value)}"
  end

  defp validation_subscores(entry) do
    ids =
      Map.get(
        entry.validation.metadata,
        :validation_ids,
        Map.get(
          entry.validation.metadata,
          "validation_ids",
          indexes(length(entry.validation.scores))
        )
      )

    Map.new(Enum.zip(ids, entry.validation.scores))
  end

  defp aggregate_objective_scores(entries) do
    scores = Enum.map(entries, &mean_objectives(&1.validation.objective_scores))
    if Enum.any?(scores, &(map_size(&1) > 0)), do: scores
  end

  defp mean_objectives(nil), do: %{}

  defp mean_objectives(scores) do
    scores
    |> Enum.reduce(%{}, &merge_objectives/2)
    |> Map.new(fn {name, {total, count}} -> {name, total / count} end)
  end

  defp merge_objectives(objectives, grouped) do
    Enum.reduce(objectives, grouped, fn {name, score}, grouped ->
      Map.update(grouped, name, {score, 1}, fn {total, count} -> {total + score, count + 1} end)
    end)
  end

  defp optional_frontier(candidate_results, policy) do
    if Enum.any?(candidate_results, fn {_id, result} ->
         is_list(result.objective_scores) and
           Enum.any?(result.objective_scores, &(map_size(&1) > 0))
       end),
       do: frontier(candidate_results, policy)
  end

  defp frontier(candidate_results, policy) do
    candidate_results
    |> Frontier.mapping(policy)
    |> Map.new(fn {dimension, ids} -> {dimension, ids |> MapSet.to_list() |> Enum.sort()} end)
  end

  defp dump_frontier(nil), do: nil

  defp dump_frontier(frontier) do
    frontier
    |> Enum.sort_by(fn {dimension, _ids} -> inspect(dimension) end)
    |> Enum.map(fn {dimension, ids} -> %{dimension: dimension, candidates: ids} end)
  end

  defp load_frontier(nil), do: nil

  defp load_frontier(rows) when is_list(rows) do
    Map.new(rows, fn row ->
      {fetch(row, :dimension, nil), fetch(row, :candidates, [])}
    end)
  end

  defp load_frontier(frontier) when is_map(frontier), do: frontier

  defp indexes(0), do: []
  defp indexes(size), do: Enum.to_list(0..(size - 1))

  defp fetch(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
