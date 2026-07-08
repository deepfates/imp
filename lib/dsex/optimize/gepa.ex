defmodule DSEx.Optimize.GEPA do
  @moduledoc """
  Pareto-aware reflective optimizer for arbitrary text artifacts.

  This module builds on `DSEx.Optimize.Anything` and adds GEPA-style mechanics:
  per-example scores, Actionable Side Information diagnostics, mutation lineage,
  Pareto frontier selection, and system-aware merges of complementary candidates.
  """

  alias DSEx.Optimize.Anything
  alias DSEx.Optimize.Anything.Artifact

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

  @option_schema [
    examples: [type: {:list, :any}, default: []],
    dev_examples: [type: {:list, :any}, default: []],
    generations: [type: :any, default: 4],
    mutation_fn: [type: :any, default: nil],
    reflection_lm: [type: :any, default: nil]
  ]

  def optimize(artifact, evaluator, opts \\ [])

  def optimize(%Artifact{} = artifact, evaluator, opts) when is_function(evaluator, 2) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimize.GEPA.optimize/3")
    examples = opts[:examples]
    dev_examples = opts[:dev_examples]
    generations = non_negative_integer(opts[:generations])
    mutation_fn = opts[:mutation_fn] || reflection_mutation_fn(opts)
    validate_mutation_fn!(mutation_fn)

    baseline = evaluate(artifact, evaluator, examples, "baseline", nil, "baseline")

    evolved =
      generations
      |> generation_indices()
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

    candidates =
      evolved
      |> Kernel.++(merged_candidates)
      |> annotate_dev_scores(evaluator, dev_examples)

    final_frontier = pareto_frontier(candidates)
    best = Enum.max_by(candidates, &selection_score/1)

    %Report{
      baseline: baseline,
      best: best,
      candidates: candidates,
      frontier: final_frontier,
      merges: merges,
      metadata: %{
        generations: generations,
        examples: length(examples),
        dev_examples: length(dev_examples),
        frontier_size: length(final_frontier),
        parent_sampling: :pareto_round_robin,
        component_selector: :actionable_side_information,
        merge_strategy: :pareto_frontier_union,
        selection_score: if(dev_examples == [], do: :train_aggregate, else: :held_out_dev)
      }
    }
  end

  def optimize(%Artifact{}, evaluator, _opts) do
    raise ArgumentError,
          "DSEx.Optimize.GEPA.optimize/3 expects an evaluator function with arity 2; got: #{inspect(evaluator)}"
  end

  defp generation_indices(count) when is_integer(count) and count > 0, do: 1..count
  defp generation_indices(_count), do: []

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

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

  defp annotate_dev_scores(candidates, _evaluator, []), do: candidates

  defp annotate_dev_scores(candidates, evaluator, dev_examples) do
    Enum.map(candidates, fn candidate ->
      dev = evaluator.(candidate.artifact, dev_examples)
      dev_scores = Map.fetch!(dev, :per_example_scores)
      dev_score = average(dev_scores)

      %{
        candidate
        | metadata:
            candidate.metadata
            |> Map.put(:dev_per_example_scores, dev_scores)
            |> Map.put(:dev_score, dev_score)
      }
    end)
  end

  defp selection_score(%Candidate{metadata: %{dev_score: score}}), do: score
  defp selection_score(%Candidate{aggregate_score: score}), do: score

  defp default_mutation(%Artifact{} = _artifact, asi, generation) do
    asi_text =
      asi
      |> Enum.map(&to_string/1)
      |> Enum.join("; ")

    "Reflection #{generation}: address #{asi_text}."
  end

  defp reflection_mutation_fn(opts) do
    case opts[:reflection_lm] do
      nil -> &default_mutation/3
      lm -> fn artifact, asi, generation -> propose_reflection(lm, artifact, asi, generation) end
    end
  end

  defp propose_reflection(lm, %Artifact{} = artifact, asi, generation) do
    messages = [
      %{
        role: :system,
        content:
          "You are a GEPA reflection proposer. Return JSON with a mutation that addresses the actionable side information."
      },
      %{
        role: :user,
        content:
          Jason.encode!(%{
            generation: generation,
            artifact: %{
              id: artifact.id,
              kind: artifact.kind,
              text: artifact.text,
              parameters: artifact.parameters
            },
            asi: asi
          })
      }
    ]

    case DSEx.LM.generate(lm, messages, []) do
      {:ok, %{"mutation" => mutation}} when is_binary(mutation) ->
        mutation

      {:ok, %{mutation: mutation}} when is_binary(mutation) ->
        mutation

      {:ok, %{"text" => text}} when is_binary(text) ->
        text

      {:ok, %{text: text}} when is_binary(text) ->
        text

      {:ok, text} when is_binary(text) ->
        text

      {:ok, other} ->
        inspect(other)

      {:error, reason} ->
        default_mutation(artifact, asi ++ ["reflection failed: #{inspect(reason)}"], generation)
    end
  end

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp validate_mutation_fn!(mutation_fn) when is_function(mutation_fn, 3), do: :ok

  defp validate_mutation_fn!(mutation_fn) do
    raise ArgumentError,
          "DSEx.Optimize.GEPA.optimize/3 expects :mutation_fn to be an arity-3 function; got: #{inspect(mutation_fn)}"
  end
end
