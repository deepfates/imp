defmodule Imp.Optimizer.GEPA.EvaluationCache do
  @moduledoc """
  Immutable per-example evaluation cache for GEPA candidates.

  Entries are keyed by deterministic digests of the complete named candidate
  and one example. This lets overlapping minibatches and validation batches
  reuse work without making batch shape part of cache identity. Trace-capturing
  evaluations should bypass lookup because reflection requires fresh execution
  trajectories; their scalar results may still be inserted for later
  non-tracing evaluations.

  The cache deliberately stores only rollout output, scalar score, and optional
  objective scores. Trajectories and actionable side information describe a
  particular execution and are not replayed as if a fresh run had occurred.
  """

  alias Imp.Optimizer.GEPA.{Candidate, Result}

  defmodule Entry do
    @moduledoc "A cached output and its scalar and optional objective scores."
    @enforce_keys [:output, :score]
    defstruct [:output, :score, :objective_scores]

    @type t :: %__MODULE__{output: term(), score: number(), objective_scores: map() | nil}
  end

  @type digest :: binary()
  @type key :: {digest(), digest()}
  @type t :: %{optional(key()) => Entry.t()}

  @doc "Returns a deterministic digest for a complete candidate."
  @spec candidate_digest(Candidate.t()) :: digest()
  def candidate_digest(candidate) do
    candidate
    |> Candidate.validate!()
    |> digest()
  end

  @doc "Partitions ordered examples into cached entries and missing indexes."
  @spec lookup(t(), Candidate.t(), [term()]) ::
          {%{optional(non_neg_integer()) => Entry.t()}, [non_neg_integer()]}
  def lookup(cache, candidate, examples) when is_map(cache) and is_list(examples) do
    candidate_digest = candidate_digest(candidate)

    examples
    |> Enum.with_index()
    |> Enum.reduce({%{}, []}, fn {example, index}, {hits, misses} ->
      case Map.fetch(cache, {candidate_digest, digest(example)}) do
        {:ok, %Entry{} = entry} -> {Map.put(hits, index, entry), misses}
        :error -> {hits, [index | misses]}
      end
    end)
    |> then(fn {hits, misses} -> {hits, Enum.reverse(misses)} end)
  end

  @doc "Stores one aligned evaluation result under its candidate/example identities."
  @spec put(t(), Candidate.t(), [term()], Result.t()) :: t()
  def put(cache, candidate, examples, %Result{} = result)
      when is_map(cache) and is_list(examples) do
    candidate = Candidate.validate!(candidate)
    result = Result.validate!(result, length(examples), candidate, false)
    candidate_digest = candidate_digest(candidate)

    objective_scores = result.objective_scores || List.duplicate(nil, length(examples))

    examples
    |> Enum.zip(result.outputs)
    |> Enum.zip(result.scores)
    |> Enum.zip(objective_scores)
    |> Enum.reduce(cache, fn {{{example, output}, score}, objectives}, cache ->
      Map.put(cache, {candidate_digest, digest(example)}, %Entry{
        output: output,
        score: score,
        objective_scores: objectives
      })
    end)
  end

  @doc "Reassembles an ordered result from cache hits and a result for missing examples."
  @spec assemble(
          [term()],
          %{optional(non_neg_integer()) => Entry.t()},
          [non_neg_integer()],
          Result.t() | nil
        ) ::
          Result.t()
  def assemble(examples, hits, missing_indexes, missing_result)
      when is_list(examples) and is_map(hits) and is_list(missing_indexes) do
    missing_entries = missing_entries!(missing_indexes, missing_result)
    entries = Map.merge(hits, missing_entries)

    ordered =
      examples
      |> Enum.with_index()
      |> Enum.map(fn {_example, index} -> Map.fetch!(entries, index) end)

    objectives = Enum.map(ordered, & &1.objective_scores)
    objective_scores = normalize_objectives!(objectives)

    metadata =
      case missing_result do
        %Result{metadata: metadata} -> metadata
        nil -> %{}
      end
      |> Map.put(:cache_hits, map_size(hits))
      |> Map.put(:cache_misses, length(missing_indexes))
      |> Map.put(:metric_calls, metric_calls(missing_result, length(missing_indexes)))

    Result.new(Enum.map(ordered, & &1.output), Enum.map(ordered, & &1.score),
      objective_scores: objective_scores,
      side_information: fresh_side_information(missing_result),
      metadata: metadata
    )
  end

  defp missing_entries!([], nil), do: %{}

  defp missing_entries!(indexes, %Result{} = result) do
    if length(indexes) != length(result.scores) do
      raise ArgumentError,
            "GEPA cache missing result must align with #{length(indexes)} missing examples"
    end

    objectives = result.objective_scores || List.duplicate(nil, length(indexes))

    indexes
    |> Enum.zip(result.outputs)
    |> Enum.zip(result.scores)
    |> Enum.zip(objectives)
    |> Map.new(fn {{{index, output}, score}, objective_scores} ->
      {index, %Entry{output: output, score: score, objective_scores: objective_scores}}
    end)
  end

  defp missing_entries!(indexes, nil) do
    raise ArgumentError,
          "GEPA cache requires an evaluation result for missing indexes: #{inspect(indexes)}"
  end

  defp metric_calls(nil, _fallback), do: 0

  defp metric_calls(%Result{metadata: metadata}, fallback) do
    case Map.get(metadata, :metric_calls, Map.get(metadata, "metric_calls")) do
      calls when is_integer(calls) and calls >= 0 -> calls
      _ -> fallback
    end
  end

  defp fresh_side_information(nil), do: %{}
  defp fresh_side_information(%Result{side_information: side_information}), do: side_information

  defp normalize_objectives!(objectives) do
    cond do
      Enum.all?(objectives, &is_nil/1) ->
        nil

      Enum.all?(objectives, &is_map/1) ->
        objectives

      true ->
        raise ArgumentError,
              "GEPA cache cannot combine evaluations with inconsistent objective-score presence"
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
end
