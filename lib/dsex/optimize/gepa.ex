defmodule DSEx.Optimize.GEPA do
  @moduledoc """
  Pareto-aware, GEPA-style reflective optimizer for arbitrary text artifacts.

  This module builds on `DSEx.Optimize.Anything` and implements the parts of the
  GEPA philosophy that fit DSEx's local artifact model: per-example scores,
  Actionable Side Information diagnostics, mutation lineage, Pareto frontier
  selection, and system-aware merges of complementary candidates.

  It is intentionally an Elixir-native optimizer over explicit artifacts and
  evaluator functions. It is not a wrapper around the Python implementation, and
  it does not by itself claim paper-scale GEPA results; use the benchmark and
  parity gates when making comparative optimizer claims.
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
      errors: [],
      frontier: [],
      merges: [],
      metadata: %{}
    ]
  end

  @option_schema [
    examples: [type: {:list, :any}, default: []],
    dev_examples: [type: {:list, :any}, default: []],
    generations: [type: :non_neg_integer, default: 4],
    mutation_fn: [
      type: {:custom, __MODULE__, :validate_mutation_fn, []},
      default: nil
    ],
    reflection_lm: [type: :any, default: nil]
  ]

  def optimize(artifact, evaluator, opts \\ [])

  def optimize(%Artifact{} = artifact, evaluator, opts) when is_function(evaluator, 2) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimize.GEPA.optimize/3")
    examples = opts[:examples]
    dev_examples = opts[:dev_examples]
    generations = opts[:generations]
    mutation_fn = opts[:mutation_fn] || reflection_mutation_fn(opts)

    baseline = evaluate(artifact, evaluator, examples, "baseline", nil, "baseline")

    evolved =
      generations
      |> generation_indices()
      |> Enum.reduce([baseline], fn generation, candidates ->
        frontier = pareto_frontier(candidates)
        parent = Enum.at(frontier, rem(generation - 1, length(frontier)))

        candidate =
          case mutate_candidate(parent, mutation_fn, generation) do
            {:ok, artifact, mutation} ->
              evaluate(artifact, evaluator, examples, "gepa-#{generation}", parent.id, mutation)

            {:error, candidate} ->
              candidate
          end

        [candidate | candidates]
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
      errors: Enum.flat_map(candidates, &candidate_errors/1),
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
    result = normalize_evaluation(evaluator.(artifact, examples), examples)

    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      aggregate_score: result.aggregate_score,
      per_example_scores: result.per_example_scores,
      asi: result.asi,
      diagnostics: result.diagnostics,
      metadata: result.metadata
    }
  rescue
    exception ->
      failed_candidate(
        artifact,
        id,
        parent_id,
        mutation,
        examples,
        Exception.message(exception),
        exception.__struct__
      )
  catch
    kind, reason ->
      failed_candidate(
        artifact,
        id,
        parent_id,
        mutation,
        examples,
        "#{kind}: #{inspect(reason)}",
        kind
      )
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

  defp mutate_candidate(%Candidate{} = parent, mutation_fn, generation) do
    mutation = mutation_fn.(parent.artifact, parent.asi, generation)
    artifact = mutate(parent.artifact, mutation, generation)
    {:ok, artifact, mutation}
  rescue
    exception ->
      {:error,
       failed_candidate(
         parent.artifact,
         "gepa-#{generation}",
         parent.id,
         :mutation_failed,
         parent.per_example_scores,
         Exception.message(exception),
         exception.__struct__
       )}
  catch
    kind, reason ->
      {:error,
       failed_candidate(
         parent.artifact,
         "gepa-#{generation}",
         parent.id,
         :mutation_failed,
         parent.per_example_scores,
         "#{kind}: #{inspect(reason)}",
         kind
       )}
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
      dev =
        evaluate(
          candidate.artifact,
          evaluator,
          dev_examples,
          "#{candidate.id}-dev",
          candidate.id,
          :dev
        )

      dev_scores = dev.per_example_scores
      dev_score = dev.aggregate_score

      dev_metadata =
        case dev.metadata do
          %{error: error} -> %{dev_error: error, dev_diagnostics: dev.diagnostics}
          _metadata -> %{}
        end

      %{
        candidate
        | metadata:
            candidate.metadata
            |> Map.merge(dev_metadata)
            |> Map.put(:dev_per_example_scores, dev_scores)
            |> Map.put(:dev_score, dev_score)
      }
    end)
  end

  defp normalize_evaluation(%{per_example_scores: per_example_scores} = result, _examples)
       when is_list(per_example_scores) do
    %{
      aggregate_score: average(per_example_scores),
      per_example_scores: per_example_scores,
      asi: List.wrap(Map.get(result, :asi, [])),
      diagnostics: List.wrap(Map.get(result, :diagnostics, [])),
      metadata: Map.get(result, :metadata, %{})
    }
  end

  defp normalize_evaluation(result, _examples) do
    raise ArgumentError,
          "GEPA evaluator must return a map with :per_example_scores; got: #{inspect(result)}"
  end

  defp failed_candidate(
         %Artifact{} = artifact,
         id,
         parent_id,
         mutation,
         examples_or_scores,
         message,
         error
       ) do
    per_example_scores = zero_scores(examples_or_scores)

    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      aggregate_score: 0.0,
      per_example_scores: per_example_scores,
      asi: [],
      diagnostics: [message],
      metadata: %{error: error}
    }
  end

  defp zero_scores(scores) when is_list(scores) do
    Enum.map(scores, fn _ -> 0.0 end)
  end

  defp candidate_errors(%Candidate{metadata: %{error: error}} = candidate) do
    [%{candidate_id: candidate.id, error: inspect(error), diagnostics: candidate.diagnostics}]
  end

  defp candidate_errors(%Candidate{metadata: %{dev_error: error}} = candidate) do
    [
      %{
        candidate_id: candidate.id,
        error: inspect(error),
        diagnostics: Map.get(candidate.metadata, :dev_diagnostics, [])
      }
    ]
  end

  defp candidate_errors(_candidate), do: []

  defp selection_score(%Candidate{metadata: %{dev_error: _error}, aggregate_score: score}),
    do: score

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

  def validate_mutation_fn(nil), do: {:ok, nil}
  def validate_mutation_fn(mutation_fn) when is_function(mutation_fn, 3), do: {:ok, mutation_fn}

  def validate_mutation_fn(mutation_fn) do
    {:error, "expected nil or an arity-3 function, got: #{inspect(mutation_fn)}"}
  end
end
