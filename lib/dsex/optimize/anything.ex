defmodule DSEx.Optimize.Anything do
  @moduledoc """
  Optimizes text and named-component systems against evaluator feedback.

  Binary, map, and seedless candidates use the production GEPA engine through
  a backend-agnostic frontend. Dataset options select single-task, multi-task,
  or held-out generalization mode. Evaluators may return a score or structured
  Actionable Side Information, while `DSEx.Optimize.Anything.Config` controls
  reflection, budgets, selection, caching, merge, stopping, and tracking.

  The `Artifact` API remains available for compatibility and delegates to the
  same engine while preserving its aggregate evaluator and report contracts.
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

    def from_map(state) when is_map(state) do
      case fetch_value(state, :type) do
        "optimize_anything_report" ->
          report_from_map(state)

        other ->
          raise ArgumentError,
                "DSEx.Optimize.Anything.Report.from_map/1 expects type #{inspect("optimize_anything_report")}; got: #{inspect(other)}"
      end
    end

    def from_map(state) do
      raise ArgumentError,
            "DSEx.Optimize.Anything.Report.from_map/1 expects a map; got: #{inspect(state)}"
    end

    defp report_from_map(state) do
      %__MODULE__{
        best: candidate_from_map(fetch_value(state, :best)),
        baseline: candidate_from_map(fetch_value(state, :baseline)),
        candidates:
          state
          |> fetch_value(:candidates, [])
          |> require_list!("DSEx.Optimize.Anything.Report.from_map/1 :candidates")
          |> Enum.map(&candidate_from_map/1),
        errors: fetch_value(state, :errors, []),
        metadata:
          state
          |> fetch_value(:metadata, %{})
          |> normalize_report_metadata()
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

    defp candidate_from_map(state) when is_map(state) do
      %Candidate{
        id: fetch_value(state, :id),
        artifact: artifact_from_map(fetch_value(state, :artifact)),
        score: fetch_value(state, :score),
        parent_id: fetch_value(state, :parent_id),
        mutation: fetch_value(state, :mutation),
        diagnostics: fetch_value(state, :diagnostics, []),
        metadata: state |> fetch_value(:metadata, %{}) |> normalize_keys()
      }
    end

    defp candidate_from_map(state) do
      raise ArgumentError,
            "DSEx.Optimize.Anything.Report.from_map/1 expects candidates to be maps or nil; got: #{inspect(state)}"
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

    defp artifact_from_map(nil), do: nil

    defp artifact_from_map(state) when is_map(state) do
      %Artifact{
        id: fetch_value(state, :id),
        kind: state |> fetch_value(:kind) |> existing_atom_or_string(),
        text: fetch_value(state, :text),
        parameters: state |> fetch_value(:parameters, %{}) |> normalize_keys(),
        metadata: state |> fetch_value(:metadata, %{}) |> normalize_keys()
      }
    end

    defp artifact_from_map(state) do
      raise ArgumentError,
            "DSEx.Optimize.Anything.Report.from_map/1 expects artifacts to be maps or nil; got: #{inspect(state)}"
    end

    defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

    defp normalize_report_metadata(metadata) do
      metadata
      |> normalize_keys()
      |> Map.update(:artifact_kind, nil, fn
        value when is_binary(value) -> existing_atom_or_string(value)
        value -> value
      end)
      |> Map.update(:engine, nil, fn
        value when is_binary(value) -> existing_atom_or_string(value)
        value -> value
      end)
      |> Map.update(:stop_reason, nil, fn
        value when is_binary(value) -> existing_atom_or_string(value)
        value -> value
      end)
    end

    defp normalize_keys(map) when is_map(map) or is_list(map) do
      Map.new(map, fn
        {key, value} -> {existing_atom_or_string(to_string(key)), value}
        invalid -> invalid_key_value!(invalid)
      end)
    end

    defp normalize_keys(value) do
      raise ArgumentError,
            "DSEx.Optimize.Anything.Report.from_map/1 expects metadata and parameters to be maps or key-value lists; got: #{inspect(value)}"
    end

    defp invalid_key_value!(invalid) do
      raise ArgumentError,
            "DSEx.Optimize.Anything.Report.from_map/1 expects metadata and parameters as key-value pairs; got entry: #{inspect(invalid)}"
    end

    defp require_list!(value, _context) when is_list(value), do: value

    defp require_list!(value, context) do
      raise ArgumentError, "#{context} expects a list; got: #{inspect(value)}"
    end

    defp fetch_value(map, key, default \\ nil) when is_atom(key),
      do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

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
    seed: [type: :integer, default: 0],
    examples: [type: {:list, :any}, default: []],
    trials: [type: :non_neg_integer, default: 8],
    mutation_fn: [
      type: {:custom, __MODULE__, :validate_mutation_fn, []},
      default: nil
    ]
  ]

  alias DSEx.Optimize.Anything.{Config, Result, Runner}

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
    legacy =
      DSEx.Options.validate!(opts, @optimize_option_schema, "DSEx.Optimize.Anything.optimize/3")

    mutation_fn = legacy[:mutation_fn] || (&default_mutation/3)
    candidate_iterations = :ets.new(:dsex_optimize_anything_legacy_ids, [:set, :public])

    try do
      runner_evaluator =
        legacy_evaluator(artifact, evaluator, legacy[:examples], candidate_iterations)

      result =
        Runner.run(%{main: artifact.text}, runner_evaluator,
          config:
            Config.new(
              engine: [
                seed: legacy[:seed],
                max_candidate_proposals: legacy[:trials],
                raise_on_exception: false,
                frontier_type: :instance
              ]
            ),
          fallback_proposer:
            legacy_proposer(artifact, mutation_fn, legacy[:seed], candidate_iterations)
        )

      legacy_report(result, artifact, legacy)
    after
      :ets.delete(candidate_iterations)
    end
  end

  def optimize(%Artifact{}, evaluator, _opts) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.optimize/3 expects an evaluator function with arity 2; got: #{inspect(evaluator)}"
  end

  def optimize(seed_candidate, evaluator, opts)
      when (is_binary(seed_candidate) or is_map(seed_candidate) or is_nil(seed_candidate)) and
             is_function(evaluator) and is_list(opts) do
    Runner.run(seed_candidate, evaluator, opts)
  end

  def optimize(seed_candidate, evaluator, opts) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.optimize/3 expects a text/named seed, evaluator function, and keyword options; got: " <>
            "#{inspect(seed_candidate)}, #{inspect(evaluator)}, #{inspect(opts)}"
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

  def validate_mutation_fn(nil), do: {:ok, nil}
  def validate_mutation_fn(mutation_fn) when is_function(mutation_fn, 3), do: {:ok, mutation_fn}

  def validate_mutation_fn(mutation_fn) do
    {:error, "expected nil or an arity-3 function, got: #{inspect(mutation_fn)}"}
  end

  defp default_mutation(%Artifact{} = artifact, trial, seed) do
    marker = "candidate #{trial + seed}"

    cond do
      artifact.kind in [:prompt, :instruction] -> "Add explicit success criteria: #{marker}."
      artifact.kind in [:code, :config] -> "# Optimization note: #{marker}"
      true -> "Optimization note: #{marker}."
    end
  end

  defp legacy_evaluator(artifact, evaluator, examples, candidate_iterations) do
    fn candidate ->
      evaluator.(legacy_artifact(artifact, candidate, candidate_iterations), examples)
    end
  end

  defp legacy_proposer(artifact, mutation_fn, seed, candidate_iterations) do
    fn candidate, :main, _records, iteration ->
      current = artifact_from_candidate(artifact, candidate, iteration)

      text =
        case mutation_fn.(current, iteration, seed) do
          {:replace, text} when is_binary(text) ->
            text

          text when is_binary(text) ->
            String.trim(current.text <> "\n" <> text)

          invalid ->
            raise ArgumentError, "legacy mutation must return text, got: #{inspect(invalid)}"
        end

      :ets.insert(candidate_iterations, {Map.put(candidate, :main, text), iteration})
      text
    end
  end

  defp legacy_artifact(artifact, candidate, candidate_iterations) do
    iteration =
      case :ets.lookup(candidate_iterations, candidate) do
        [{^candidate, iteration}] -> iteration
        [] -> nil
      end

    artifact_from_candidate(artifact, candidate, iteration)
  end

  defp legacy_report(%Result{} = result, artifact, legacy) do
    candidate_ids = legacy_candidate_ids(result.history)

    accepted =
      result.candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} ->
        id = Map.fetch!(candidate_ids, index)
        parent_index = result.parents |> Enum.fetch!(index) |> List.first()

        %Candidate{
          id: id,
          artifact: artifact_from_candidate(artifact, candidate, id),
          score: Enum.fetch!(result.validation_scores, index),
          parent_id: Map.get(candidate_ids, parent_index),
          mutation: if(index == 0, do: "baseline", else: "accepted reflection"),
          diagnostics: diagnostics(Enum.at(result.candidate_side_information, index, %{}))
        }
      end)

    rejected = Enum.map(result.rejected, &legacy_rejected_candidate(&1, artifact, candidate_ids))
    candidates = accepted ++ rejected
    best = Enum.fetch!(accepted, Result.best_index(result))

    %Report{
      baseline: hd(accepted),
      best: best,
      candidates: candidates,
      errors: Enum.flat_map(rejected, &candidate_error/1),
      metadata: %{
        seed: legacy[:seed],
        trials: legacy[:trials],
        artifact_kind: artifact.kind,
        evaluator_examples: length(legacy[:examples]),
        engine: DSEx.Optimizer.GEPA.Engine,
        stop_reason: result.stop_reason,
        metric_calls: result.total_metric_calls
      }
    }
  end

  defp legacy_rejected_candidate(event, artifact, candidate_ids) do
    iteration = Map.get(event, :iteration, Map.get(event, "iteration", 0))
    candidate = Map.get(event, :candidate, Map.get(event, "candidate")) || %{main: artifact.text}
    reason = Map.get(event, :reason, Map.get(event, "reason"))
    message = rejection_message(reason) || side_information_error(event)

    %Candidate{
      id: candidate_id(iteration),
      artifact: artifact_from_candidate(artifact, candidate, iteration),
      score: Map.get(event, :minibatch_candidate_score, 0.0) || 0.0,
      parent_id:
        event
        |> Map.get(:parent_ids, Map.get(event, "parent_ids", []))
        |> List.first()
        |> then(&Map.get(candidate_ids, &1)),
      mutation: if(match?({:proposal_error, _}, reason), do: :mutation_failed, else: "rejected"),
      diagnostics: if(message, do: [message], else: []),
      metadata: if(message, do: %{error: reason}, else: %{})
    }
  end

  defp artifact_from_candidate(artifact, candidate, id) do
    text = Map.get(candidate, :main, Map.get(candidate, "main", artifact.text))

    %{
      artifact
      | id: if(is_nil(id), do: artifact.id, else: normalize_candidate_id(id)),
        text: text,
        parameters: Map.put(artifact.parameters, :main, text)
    }
  end

  defp normalize_candidate_id(id) when is_binary(id), do: id
  defp normalize_candidate_id(iteration), do: candidate_id(iteration)

  defp diagnostics(side_information) do
    side_information
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      %{"diagnostics" => diagnostics} -> List.wrap(diagnostics)
      %{diagnostics: diagnostics} -> List.wrap(diagnostics)
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp rejection_message({:proposal_error, {:proposal_exception, message}}), do: message
  defp rejection_message({:proposal_error, reason}), do: inspect(reason)
  defp rejection_message(_reason), do: nil

  defp side_information_error(event) do
    event
    |> Map.get(:candidate_side_information, Map.get(event, "candidate_side_information", %{}))
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(fn
      %{"error" => message} when is_binary(message) -> message
      %{error: message} when is_binary(message) -> message
      _ -> nil
    end)
  end

  defp legacy_candidate_ids(history) do
    Enum.reduce(history, %{0 => "baseline"}, fn event, ids ->
      status = Map.get(event, :status, Map.get(event, "status"))
      engine_id = Map.get(event, :candidate_id, Map.get(event, "candidate_id"))
      iteration = Map.get(event, :iteration, Map.get(event, "iteration"))

      if status in [:accepted, "accepted"] and is_integer(engine_id) and is_integer(iteration) do
        Map.put(ids, engine_id, candidate_id(iteration))
      else
        ids
      end
    end)
  end

  defp candidate_error(%Candidate{metadata: %{error: error}} = candidate) do
    [%{candidate_id: candidate.id, error: inspect(error), diagnostics: candidate.diagnostics}]
  end

  defp candidate_error(_candidate), do: []

  defp stable_id(kind, text) do
    hash = :crypto.hash(:sha256, "#{kind}:#{text}") |> Base.encode16(case: :lower)
    "#{kind}-#{String.slice(hash, 0, 12)}"
  end

  defp candidate_id(nil), do: nil
  defp candidate_id(0), do: "baseline"
  defp candidate_id(trial), do: "candidate-#{trial}"
end
