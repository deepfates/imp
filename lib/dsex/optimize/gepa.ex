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
  alias DSEx.Optimizer.GEPA.Pareto

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
    reflection_lm: [type: {:custom, DSEx.LM, :validate_lm, []}, default: nil],
    seed: [type: :non_neg_integer, default: 0],
    resume_state: [type: {:custom, __MODULE__, :validate_resume_state, []}, default: nil],
    checkpoint_fn: [type: {:custom, __MODULE__, :validate_checkpoint_fn, []}, default: nil]
  ]

  def optimize(artifact, evaluator, opts \\ [])

  def optimize(%Artifact{} = artifact, evaluator, opts) when is_function(evaluator, 2) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimize.GEPA.optimize/3")
    examples = opts[:examples]
    dev_examples = opts[:dev_examples]
    generations = opts[:generations]
    mutation_fn = opts[:mutation_fn] || reflection_mutation_fn(opts)

    {evolved, rng_state} =
      case opts[:resume_state] do
        nil ->
          baseline = evaluate(artifact, evaluator, examples, "baseline", nil, "baseline")
          rng_state = seed_rng(opts[:seed])
          checkpoint!([baseline], rng_state, opts[:checkpoint_fn])
          {[baseline], rng_state}

        state ->
          load_resume_state!(state, artifact, examples, generations, opts[:seed])
      end

    {evolved, _rng_state} =
      generations
      |> generation_indices()
      |> Enum.reduce({evolved, rng_state}, fn generation, {candidates, rng_state} ->
        if Enum.any?(candidates, &(&1.id == "gepa-#{generation}")) do
          {candidates, rng_state}
        else
          {parent, rng_state} = sample_parent(candidates, rng_state)

          candidate =
            case mutate_candidate(parent, mutation_fn, generation) do
              {:ok, artifact, mutation} ->
                evaluate(artifact, evaluator, examples, "gepa-#{generation}", parent.id, mutation)

              {:error, candidate} ->
                candidate
            end

          updated = candidates ++ [candidate]
          checkpoint!(updated, rng_state, opts[:checkpoint_fn])
          {updated, rng_state}
        end
      end)

    frontier = pareto_frontier(evolved)
    {merged_candidates, merges} = merge_frontier(frontier, evaluator, examples)

    candidates =
      evolved
      |> Kernel.++(merged_candidates)
      |> annotate_dev_scores(evaluator, dev_examples)

    baseline = hd(candidates)
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
        parent_sampling: :pareto_coverage_weighted,
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

  @doc "Serializes completed GEPA evolution candidates for durable resume."
  def dump_resume_state(candidates) when is_list(candidates) do
    dump_resume_state(candidates, advance_rng(seed_rng(0), max(length(candidates) - 1, 0)))
  end

  def dump_resume_state(candidates) do
    raise ArgumentError,
          "DSEx.Optimize.GEPA.dump_resume_state/1 expects a candidate list; got: #{inspect(candidates)}"
  end

  defp dump_resume_state(candidates, rng_state) do
    %{
      "schema_version" => 2,
      "phase" => "evolution",
      "rng_state" => dump_rng(rng_state),
      "candidates" => Enum.map(candidates, &dump_candidate!/1)
    }
  end

  defp generation_indices(count) when is_integer(count) and count > 0, do: 1..count
  defp generation_indices(_count), do: []

  def pareto_frontier(candidates) do
    scores =
      Enum.map(candidates, fn candidate ->
        {candidate.id,
         candidate.per_example_scores
         |> Enum.with_index()
         |> Map.new(fn {score, index} -> {index, score} end)}
      end)

    aggregate_scores = Map.new(candidates, &{&1.id, &1.aggregate_score})

    frontier_ids =
      scores |> Pareto.winner_mapping() |> Pareto.candidate_ids(aggregate_scores) |> MapSet.new()

    candidates
    |> Enum.filter(&MapSet.member?(frontier_ids, &1.id))
    |> Enum.sort_by(& &1.aggregate_score, :desc)
  end

  defp sample_parent(candidates, rng_state) do
    scores =
      Enum.map(candidates, fn candidate ->
        {candidate.id,
         candidate.per_example_scores
         |> Enum.with_index()
         |> Map.new(fn {score, index} -> {index, score} end)}
      end)

    aggregate_scores = Map.new(candidates, &{&1.id, &1.aggregate_score})

    {id, rng_state} =
      scores |> Pareto.winner_mapping() |> Pareto.sample(aggregate_scores, rng_state)

    {Enum.find(candidates, &(&1.id == id)), rng_state}
  end

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

  defp checkpoint!(candidates, _rng_state, nil) do
    emit_progress(candidates)
    :ok
  end

  defp checkpoint!(candidates, rng_state, checkpoint_fn) do
    emit_progress(candidates)

    case checkpoint_fn.(dump_resume_state(candidates, rng_state)) do
      :ok ->
        :ok

      other ->
        raise ArgumentError, "GEPA checkpoint callback must return :ok; got: #{inspect(other)}"
    end
  end

  defp emit_progress(candidates) do
    candidate = List.last(candidates)

    DSEx.Telemetry.execute(
      [:dsex, :optimizer, :progress],
      %{
        completed_generations: max(length(candidates) - 1, 0),
        candidate_count: length(candidates)
      },
      %{optimizer: :gepa, candidate_id: candidate.id, aggregate_score: candidate.aggregate_score}
    )
  end

  defp load_resume_state!(
         %{"schema_version" => 1, "phase" => "evolution", "candidates" => states},
         artifact,
         examples,
         generations,
         seed
       )
       when is_list(states) do
    candidates = validate_resume_candidates!(states, artifact, examples, generations)
    {candidates, advance_rng(seed_rng(seed), max(length(candidates) - 1, 0))}
  end

  defp load_resume_state!(
         %{
           "schema_version" => 2,
           "phase" => "evolution",
           "rng_state" => rng_state,
           "candidates" => states
         },
         artifact,
         examples,
         generations,
         _seed
       )
       when is_list(states) do
    {validate_resume_candidates!(states, artifact, examples, generations), load_rng!(rng_state)}
  end

  defp load_resume_state!(_state, _artifact, _examples, _generations, _seed) do
    raise ArgumentError, "invalid GEPA resume state schema"
  end

  defp validate_resume_candidates!(states, artifact, examples, generations) do
    candidates = Enum.map(states, &load_candidate!/1)

    expected_ids = [
      "baseline" | Enum.map(generation_indices(length(candidates) - 1), &"gepa-#{&1}")
    ]

    unless candidates != [] and Enum.map(candidates, & &1.id) == expected_ids and
             length(candidates) <= generations + 1 and hd(candidates).artifact == artifact and
             Enum.all?(candidates, &(length(&1.per_example_scores) == length(examples))) and
             valid_resume_lineage?(candidates) do
      raise ArgumentError, "GEPA resume state does not match the requested optimization"
    end

    candidates
  end

  defp seed_rng(seed), do: :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})

  defp advance_rng(rng_state, count) do
    Enum.reduce(1..count//1, rng_state, fn _, rng_state -> elem(:rand.uniform_s(rng_state), 1) end)
  end

  defp dump_rng(rng_state) do
    {:exsss, [first | second]} = :rand.export_seed_s(rng_state)
    %{"algorithm" => "exsss", "words" => [first, second]}
  end

  defp load_rng!(%{"algorithm" => "exsss", "words" => [first, second]})
       when is_integer(first) and is_integer(second) do
    :rand.seed_s({:exsss, [first | second]})
  end

  defp load_rng!(state), do: raise(ArgumentError, "invalid GEPA RNG state: #{inspect(state)}")

  defp valid_resume_lineage?([%Candidate{id: "baseline", parent_id: nil} | rest]) do
    rest
    |> Enum.with_index(1)
    |> Enum.all?(fn {candidate, index} ->
      prior_ids = ["baseline" | Enum.map(generation_indices(index - 1), &"gepa-#{&1}")]
      candidate.parent_id in prior_ids
    end)
  end

  defp valid_resume_lineage?(_candidates), do: false

  defp dump_candidate!(%Candidate{} = candidate) do
    DSEx.Optimizer.Report.json_safe(%{
      "id" => candidate.id,
      "artifact" => Map.from_struct(candidate.artifact),
      "parent_id" => candidate.parent_id,
      "mutation" => candidate.mutation,
      "aggregate_score" => candidate.aggregate_score,
      "per_example_scores" => candidate.per_example_scores,
      "asi" => candidate.asi,
      "diagnostics" => candidate.diagnostics,
      "metadata" => candidate.metadata
    })
  end

  defp dump_candidate!(candidate) do
    raise ArgumentError, "GEPA resume state expects candidates; got: #{inspect(candidate)}"
  end

  defp load_candidate!(state) when is_map(state) do
    state =
      Map.new(state, fn {key, value} ->
        {key, DSEx.Optimizer.Report.restore_json_safe(value)}
      end)

    artifact = state |> Map.fetch!("artifact") |> then(&struct!(Artifact, &1))
    scores = Map.fetch!(state, "per_example_scores")
    aggregate_score = Map.fetch!(state, "aggregate_score")

    unless is_list(scores) and Enum.all?(scores, &is_number/1) and is_number(aggregate_score) do
      raise ArgumentError, "GEPA resume candidate scores must be numeric"
    end

    %Candidate{
      id: Map.fetch!(state, "id"),
      artifact: artifact,
      parent_id: Map.get(state, "parent_id"),
      mutation: Map.get(state, "mutation"),
      aggregate_score: aggregate_score,
      per_example_scores: scores,
      asi: Map.get(state, "asi", []),
      diagnostics: Map.get(state, "diagnostics", []),
      metadata: Map.get(state, "metadata", %{})
    }
  end

  defp load_candidate!(state),
    do: raise(ArgumentError, "GEPA resume candidates must be maps; got: #{inspect(state)}")

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  def validate_mutation_fn(nil), do: {:ok, nil}
  def validate_mutation_fn(mutation_fn) when is_function(mutation_fn, 3), do: {:ok, mutation_fn}

  def validate_mutation_fn(mutation_fn) do
    {:error, "expected nil or an arity-3 function, got: #{inspect(mutation_fn)}"}
  end

  def validate_resume_state(nil), do: {:ok, nil}
  def validate_resume_state(state) when is_map(state), do: {:ok, state}

  def validate_resume_state(state),
    do: {:error, "expected nil or a resume-state map, got: #{inspect(state)}"}

  def validate_checkpoint_fn(nil), do: {:ok, nil}

  def validate_checkpoint_fn(checkpoint_fn) when is_function(checkpoint_fn, 1),
    do: {:ok, checkpoint_fn}

  def validate_checkpoint_fn(checkpoint_fn),
    do: {:error, "expected nil or an arity-1 function, got: #{inspect(checkpoint_fn)}"}
end
