defmodule DSPy.Optimize.Anything do
  @moduledoc """
  Optimizes arbitrary text artifacts against evaluator feedback.

  The API is deliberately small: provide an artifact, examples, an evaluator,
  and optional mutation strategy. The optimizer keeps the baseline candidate,
  evaluates deterministic candidate mutations, and returns a report with
  scores, diagnostics, and lineage.
  """

  defmodule Artifact do
    @moduledoc "Text artifact under optimization."
    defstruct [:id, :kind, :text, metadata: %{}]
  end

  defmodule Evaluation do
    @moduledoc "Evaluator result for a candidate artifact."
    defstruct score: 0.0, diagnostics: [], metadata: %{}
  end

  defmodule Candidate do
    @moduledoc "Evaluated artifact candidate with lineage."
    defstruct [
      :id,
      :artifact,
      :score,
      :parent_id,
      :mutation,
      diagnostics: [],
      metadata: %{}
    ]
  end

  defmodule Report do
    @moduledoc "Complete Optimize.Anything result."
    defstruct [
      :best,
      :baseline,
      candidates: [],
      errors: [],
      metadata: %{}
    ]

    def to_map(%__MODULE__{} = report) do
      %{
        "type" => "optimize_anything_report",
        "best" => candidate_to_map(report.best),
        "baseline" => candidate_to_map(report.baseline),
        "candidates" => Enum.map(report.candidates, &candidate_to_map/1),
        "errors" => report.errors,
        "metadata" => stringify_keys(report.metadata)
      }
    end

    def from_map(%{"type" => "optimize_anything_report"} = state) do
      %__MODULE__{
        best: candidate_from_map(state["best"]),
        baseline: candidate_from_map(state["baseline"]),
        candidates: Enum.map(state["candidates"] || [], &candidate_from_map/1),
        errors: state["errors"] || [],
        metadata: normalize_report_metadata(state["metadata"] || %{})
      }
    end

    defp candidate_to_map(nil), do: nil

    defp candidate_to_map(%Candidate{} = candidate) do
      %{
        "id" => candidate.id,
        "artifact" => artifact_to_map(candidate.artifact),
        "score" => candidate.score,
        "parent_id" => candidate.parent_id,
        "mutation" => candidate.mutation,
        "diagnostics" => candidate.diagnostics,
        "metadata" => stringify_keys(candidate.metadata)
      }
    end

    defp candidate_from_map(nil), do: nil

    defp candidate_from_map(state) do
      %Candidate{
        id: state["id"],
        artifact: artifact_from_map(state["artifact"]),
        score: state["score"],
        parent_id: state["parent_id"],
        mutation: state["mutation"],
        diagnostics: state["diagnostics"] || [],
        metadata: atomize_keys(state["metadata"] || %{})
      }
    end

    defp artifact_to_map(%Artifact{} = artifact) do
      %{
        "id" => artifact.id,
        "kind" => Atom.to_string(artifact.kind),
        "text" => artifact.text,
        "metadata" => stringify_keys(artifact.metadata)
      }
    end

    defp artifact_from_map(state) do
      %Artifact{
        id: state["id"],
        kind: String.to_atom(state["kind"]),
        text: state["text"],
        metadata: atomize_keys(state["metadata"] || %{})
      }
    end

    defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

    defp normalize_report_metadata(metadata) do
      metadata
      |> atomize_keys()
      |> Map.update(:artifact_kind, nil, fn
        value when is_binary(value) -> String.to_atom(value)
        value -> value
      end)
    end

    defp atomize_keys(map),
      do: Map.new(map, fn {key, value} -> {String.to_atom(to_string(key)), value} end)
  end

  def new_artifact(kind, text, opts \\ []) when is_binary(text) do
    %Artifact{
      id: Keyword.get(opts, :id, stable_id(kind, text)),
      kind: kind,
      text: text,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def optimize(%Artifact{} = artifact, evaluator, opts \\ []) when is_function(evaluator, 2) do
    seed = Keyword.get(opts, :seed, 0)
    examples = Keyword.get(opts, :examples, [])
    trials = Keyword.get(opts, :trials, 8)
    mutation_fn = Keyword.get(opts, :mutation_fn, &default_mutation/3)

    baseline = evaluate_candidate(artifact, evaluator, examples, "baseline", nil, "baseline")

    candidates =
      1..trials
      |> Enum.reduce([baseline], fn trial, candidates ->
        parent = select_parent(candidates)
        mutation = mutation_fn.(parent.artifact, trial, seed)
        artifact = apply_mutation(parent.artifact, mutation, trial)

        [
          evaluate_candidate(
            artifact,
            evaluator,
            examples,
            candidate_id(trial),
            parent.id,
            mutation
          )
          | candidates
        ]
      end)
      |> Enum.reverse()

    best = select_parent(candidates)

    %Report{
      baseline: baseline,
      best: best,
      candidates: candidates,
      metadata: %{
        seed: seed,
        trials: trials,
        artifact_kind: artifact.kind,
        evaluator_examples: length(examples)
      }
    }
  end

  def save_report!(%Report{} = report, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(Report.to_map(report), pretty: true))
    :ok
  end

  def load_report!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Report.from_map()
  end

  defp evaluate_candidate(%Artifact{} = artifact, evaluator, examples, id, parent_id, mutation) do
    evaluation =
      case evaluator.(artifact, examples) do
        %Evaluation{} = evaluation ->
          evaluation

        %{score: _score} = result ->
          struct(Evaluation, Map.take(result, [:score, :diagnostics, :metadata]))

        score when is_number(score) ->
          %Evaluation{score: score}
      end

    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      score: evaluation.score,
      diagnostics: List.wrap(evaluation.diagnostics),
      metadata: evaluation.metadata
    }
  end

  defp select_parent(candidates), do: Enum.max_by(candidates, & &1.score)

  defp default_mutation(%Artifact{} = artifact, trial, seed) do
    marker = "candidate #{trial + seed}"

    cond do
      artifact.kind in [:prompt, :instruction] -> "Add explicit success criteria: #{marker}."
      artifact.kind in [:code, :config] -> "# Optimization note: #{marker}"
      true -> "Optimization note: #{marker}."
    end
  end

  defp apply_mutation(%Artifact{} = artifact, mutation, trial) do
    %{artifact | id: candidate_id(trial), text: String.trim(artifact.text <> "\n" <> mutation)}
  end

  defp stable_id(kind, text) do
    hash = :crypto.hash(:sha256, "#{kind}:#{text}") |> Base.encode16(case: :lower)
    "#{kind}-#{String.slice(hash, 0, 12)}"
  end

  defp candidate_id(trial), do: "candidate-#{trial}"
end
