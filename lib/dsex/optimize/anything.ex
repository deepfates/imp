defmodule DSEx.Optimize.Anything do
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
        "kind" => to_string(artifact.kind),
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

  @artifact_option_schema [
    id: [type: :string],
    parameters: [type: :map, default: %{}],
    metadata: [type: :map, default: %{}]
  ]

  @optimize_option_schema [
    seed: [type: :any, default: 0],
    examples: [type: {:list, :any}, default: []],
    trials: [type: :any, default: 8],
    mutation_fn: [type: :any, default: nil]
  ]

  def new_artifact(kind, text, opts \\ [])

  def new_artifact(kind, text, opts) when is_binary(text) do
    opts =
      DSEx.Options.validate!(
        opts,
        @artifact_option_schema,
        "DSEx.Optimize.Anything.new_artifact/3"
      )

    parameters =
      opts[:parameters]
      |> Map.put_new(:main, text)

    %Artifact{
      id: opts[:id] || stable_id(kind, text),
      kind: kind,
      text: text,
      parameters: parameters,
      metadata: opts[:metadata]
    }
  end

  def new_artifact(_kind, text, _opts) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.new_artifact/3 expects artifact text to be a binary; got: #{inspect(text)}"
  end

  def optimize(artifact, evaluator, opts \\ [])

  def optimize(%Artifact{} = artifact, evaluator, opts) when is_function(evaluator, 2) do
    opts =
      DSEx.Options.validate!(opts, @optimize_option_schema, "DSEx.Optimize.Anything.optimize/3")

    seed = opts[:seed]
    examples = opts[:examples]
    trials = non_negative_integer(opts[:trials])
    mutation_fn = opts[:mutation_fn] || (&default_mutation/3)
    validate_mutation_fn!(mutation_fn)

    baseline = evaluate_candidate(artifact, evaluator, examples, "baseline", nil, "baseline")

    {candidates, errors} =
      trials
      |> trial_indices()
      |> Enum.reduce({[baseline], error_list(baseline)}, fn trial, {candidates, errors} ->
        parent = select_parent(candidates)

        candidate =
          case mutate_candidate(parent, mutation_fn, trial, seed) do
            {:ok, artifact, mutation} ->
              evaluate_candidate(
                artifact,
                evaluator,
                examples,
                candidate_id(trial),
                parent.id,
                mutation
              )

            {:error, candidate} ->
              candidate
          end

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

  def optimize(%Artifact{}, evaluator, _opts) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.optimize/3 expects an evaluator function with arity 2; got: #{inspect(evaluator)}"
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

  defp mutate_candidate(%Candidate{} = parent, mutation_fn, trial, seed) do
    mutation = mutation_fn.(parent.artifact, trial, seed)
    artifact = apply_mutation(parent.artifact, mutation, trial)
    {:ok, artifact, mutation}
  rescue
    exception ->
      {:error,
       failed_candidate(
         parent.artifact,
         candidate_id(trial),
         parent.id,
         :mutation_failed,
         Exception.message(exception),
         exception.__struct__
       )}
  catch
    kind, reason ->
      {:error,
       failed_candidate(
         parent.artifact,
         candidate_id(trial),
         parent.id,
         :mutation_failed,
         "#{kind}: #{inspect(reason)}",
         kind
       )}
  end

  defp failed_candidate(%Artifact{} = artifact, id, parent_id, mutation, message, error) do
    %Candidate{
      id: id,
      artifact: artifact,
      parent_id: parent_id,
      mutation: mutation,
      score: 0.0,
      diagnostics: [message],
      metadata: %{error: error}
    }
  end

  defp select_parent(candidates), do: Enum.max_by(candidates, & &1.score)

  defp trial_indices(count) when is_integer(count) and count > 0, do: 1..count
  defp trial_indices(_count), do: []

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp validate_mutation_fn!(mutation_fn) when is_function(mutation_fn, 3), do: :ok

  defp validate_mutation_fn!(mutation_fn) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.optimize/3 expects :mutation_fn to be an arity-3 function; got: #{inspect(mutation_fn)}"
  end

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
