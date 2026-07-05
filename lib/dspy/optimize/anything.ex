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
    defstruct [:id, :kind, :text, parameters: %{}, metadata: %{}]
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
        metadata: normalize_keys(state["metadata"] || %{})
      }
    end

    defp artifact_to_map(%Artifact{} = artifact) do
      %{
        "id" => artifact.id,
        "kind" => Atom.to_string(artifact.kind),
        "text" => artifact.text,
        "parameters" => stringify_keys(artifact.parameters),
        "metadata" => stringify_keys(artifact.metadata)
      }
    end

    defp artifact_from_map(state) do
      %Artifact{
        id: state["id"],
        kind: existing_atom_or_string(state["kind"]),
        text: state["text"],
        parameters: normalize_keys(state["parameters"] || %{}),
        metadata: normalize_keys(state["metadata"] || %{})
      }
    end

    defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

    defp normalize_report_metadata(metadata) do
      metadata
      |> normalize_keys()
      |> Map.update(:artifact_kind, nil, fn
        value when is_binary(value) -> existing_atom_or_string(value)
        value -> value
      end)
    end

    defp normalize_keys(map),
      do: Map.new(map, fn {key, value} -> {existing_atom_or_string(to_string(key)), value} end)

    defp existing_atom_or_string(value) when is_atom(value), do: value

    defp existing_atom_or_string(value) when is_binary(value) do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> value
    end
  end

  def new_artifact(kind, text, opts \\ []) when is_binary(text) do
    parameters =
      opts
      |> Keyword.get(:parameters, %{})
      |> Map.put_new(:main, text)

    %Artifact{
      id: Keyword.get(opts, :id, stable_id(kind, text)),
      kind: kind,
      text: text,
      parameters: parameters,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def optimize(%Artifact{} = artifact, evaluator, opts \\ []) when is_function(evaluator, 2) do
    seed = Keyword.get(opts, :seed, 0)
    examples = Keyword.get(opts, :examples, [])
    trials = Keyword.get(opts, :trials, 8)
    mutation_fn = Keyword.get(opts, :mutation_fn, &default_mutation/3)

    baseline = evaluate_candidate(artifact, evaluator, examples, "baseline", nil, "baseline")

    {candidates, errors} =
      1..trials
      |> Enum.reduce({[baseline], error_list(baseline)}, fn trial, {candidates, errors} ->
        parent = select_parent(candidates)
        mutation = mutation_fn.(parent.artifact, trial, seed)
        artifact = apply_mutation(parent.artifact, mutation, trial)

        candidate =
          evaluate_candidate(
            artifact,
            evaluator,
            examples,
            candidate_id(trial),
            parent.id,
            mutation
          )

        {[candidate | candidates], errors ++ error_list(candidate)}
      end)

    candidates = Enum.reverse(candidates)

    best = select_parent(candidates)

    %Report{
      baseline: baseline,
      best: best,
      candidates: candidates,
      errors: errors,
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
    evaluation = normalize_evaluation(evaluator.(artifact, examples))

    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      score: evaluation.score,
      diagnostics: List.wrap(evaluation.diagnostics),
      metadata: evaluation.metadata
    }
  rescue
    exception ->
      %Candidate{
        id: id,
        artifact: artifact,
        parent_id: parent_id,
        mutation: mutation,
        score: 0.0,
        diagnostics: [Exception.message(exception)],
        metadata: %{error: inspect(exception.__struct__)}
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
    text = String.trim(artifact.text <> "\n" <> mutation)

    %{
      artifact
      | id: candidate_id(trial),
        text: text,
        parameters: Map.put(artifact.parameters, :main, text)
    }
  end

  defp normalize_evaluation(%Evaluation{} = evaluation), do: evaluation

  defp normalize_evaluation(%{score: _score} = result),
    do: struct(Evaluation, Map.take(result, [:score, :diagnostics, :metadata]))

  defp normalize_evaluation(score) when is_number(score), do: %Evaluation{score: score}

  defp normalize_evaluation({:ok, score}) when is_number(score), do: %Evaluation{score: score}

  defp normalize_evaluation({:ok, %Evaluation{} = evaluation}), do: evaluation

  defp normalize_evaluation({:error, reason}),
    do: %Evaluation{score: 0.0, diagnostics: [inspect(reason)], metadata: %{error: reason}}

  defp error_list(%Candidate{metadata: %{error: error}} = candidate) do
    [%{candidate_id: candidate.id, error: inspect(error), diagnostics: candidate.diagnostics}]
  end

  defp error_list(_candidate), do: []

  defp stable_id(kind, text) do
    hash = :crypto.hash(:sha256, "#{kind}:#{text}") |> Base.encode16(case: :lower)
    "#{kind}-#{String.slice(hash, 0, 12)}"
  end

  defp candidate_id(trial), do: "candidate-#{trial}"
end
