defmodule DSPy.Optimize.GEPA do
  @moduledoc """
  Pareto-aware reflective optimizer for arbitrary text artifacts.

  This module builds on `DSPy.Optimize.Anything` and adds GEPA-style mechanics:
  per-example scores, Actionable Side Information diagnostics, mutation lineage,
  Pareto frontier selection, and system-aware merges of complementary candidates.
  """

  alias DSPy.Optimize.Anything
  alias DSPy.Optimize.Anything.Artifact

  defmodule Candidate do
    @moduledoc "GEPA candidate with per-example scores and lineage."
    defstruct [
      :id,
      :artifact,
      :parent_id,
      :mutation,
      aggregate_score: 0.0,
      per_example_scores: [],
      asi: [],
      diagnostics: [],
      metadata: %{}
    ]
  end

  defmodule Report do
    @moduledoc "GEPA optimization report."
    defstruct [
      :best,
      baseline: nil,
      candidates: [],
      frontier: [],
      merges: [],
      metadata: %{}
    ]
  end

  def optimize(%Artifact{} = artifact, evaluator, opts \\ []) when is_function(evaluator, 2) do
    examples = Keyword.get(opts, :examples, [])
    generations = Keyword.get(opts, :generations, 4)
    mutation_fn = Keyword.get(opts, :mutation_fn, &default_mutation/3)

    baseline = evaluate(artifact, evaluator, examples, "baseline", nil, "baseline")

    evolved =
      1..generations
      |> Enum.reduce([baseline], fn generation, candidates ->
        frontier = pareto_frontier(candidates)
        parent = Enum.at(frontier, rem(generation - 1, length(frontier)))
        mutation = mutation_fn.(parent.artifact, parent.asi, generation)
        artifact = mutate(parent.artifact, mutation, generation)

        [
          evaluate(artifact, evaluator, examples, "gepa-#{generation}", parent.id, mutation)
          | candidates
        ]
      end)
      |> Enum.reverse()

    frontier = pareto_frontier(evolved)
    {merged_candidates, merges} = merge_frontier(frontier, evaluator, examples)
    candidates = evolved ++ merged_candidates
    final_frontier = pareto_frontier(candidates)
    best = Enum.max_by(candidates, & &1.aggregate_score)

    %Report{
      baseline: baseline,
      best: best,
      candidates: candidates,
      frontier: final_frontier,
      merges: merges,
      metadata: %{
        generations: generations,
        examples: length(examples),
        frontier_size: length(final_frontier)
      }
    }
  end

  def pareto_frontier(candidates) do
    candidates
    |> Enum.reject(fn candidate ->
      Enum.any?(candidates, fn other ->
        other.id != candidate.id and
          dominates?(other.per_example_scores, candidate.per_example_scores)
      end)
    end)
    |> Enum.sort_by(& &1.aggregate_score, :desc)
  end

  defp dominates?(left, right) when length(left) == length(right) do
    Enum.zip(left, right)
    |> then(fn pairs ->
      Enum.all?(pairs, fn {l, r} -> l >= r end) and Enum.any?(pairs, fn {l, r} -> l > r end)
    end)
  end

  defp dominates?(_left, _right), do: false

  defp evaluate(%Artifact{} = artifact, evaluator, examples, id, parent_id, mutation) do
    result = evaluator.(artifact, examples)

    per_example_scores = Map.fetch!(result, :per_example_scores)
    aggregate_score = average(per_example_scores)
    asi = List.wrap(Map.get(result, :asi, []))
    diagnostics = List.wrap(Map.get(result, :diagnostics, []))

    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      aggregate_score: aggregate_score,
      per_example_scores: per_example_scores,
      asi: asi,
      diagnostics: diagnostics,
      metadata: Map.get(result, :metadata, %{})
    }
  end

  defp mutate(%Artifact{} = artifact, {:replace, text}, generation) do
    text = String.trim(text)

    %{
      artifact
      | id: "gepa-#{generation}",
        text: text,
        parameters: Map.put(artifact.parameters, :main, text)
    }
  end

  defp mutate(%Artifact{} = artifact, mutation, generation) do
    text = String.trim(artifact.text <> "\n" <> mutation)

    %{
      artifact
      | id: "gepa-#{generation}",
        text: text,
        parameters: Map.put(artifact.parameters, :main, text)
    }
  end

  defp merge_frontier([_single], _evaluator, _examples), do: {[], []}
  defp merge_frontier([], _evaluator, _examples), do: {[], []}

  defp merge_frontier(frontier, evaluator, examples) do
    [left, right | _rest] = frontier
    artifact = merge_artifacts(left.artifact, right.artifact)
    merged = evaluate(artifact, evaluator, examples, "merge-#{left.id}-#{right.id}", nil, "merge")
    {[merged], [%{id: merged.id, parents: [left.id, right.id]}]}
  end

  defp merge_artifacts(%Artifact{} = left, %Artifact{} = right) do
    text =
      [left.text, right.text]
      |> Enum.flat_map(&String.split(&1, "\n", trim: true))
      |> Enum.uniq()
      |> Enum.join("\n")

    Anything.new_artifact(left.kind, text,
      id: "merge-#{left.id}-#{right.id}",
      parameters: Map.merge(left.parameters, right.parameters) |> Map.put(:main, text),
      metadata: Map.merge(left.metadata, right.metadata)
    )
  end

  defp default_mutation(%Artifact{} = _artifact, asi, generation) do
    asi_text =
      asi
      |> Enum.map(&to_string/1)
      |> Enum.join("; ")

    "Reflection #{generation}: address #{asi_text}."
  end

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)
end
