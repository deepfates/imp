defmodule Imp.Optimize.Anything do
  @moduledoc """
  Optimizes text, named text components, and JSON-safe structured artifacts
  against evaluator feedback.

  The `run/3` surface controls reflection, budgets, selection, caching,
  merging, stopping, and tracking through its options. It returns an immutable
  result value. Structured artifacts are an Imp-native extension to GEPA
  v0.1.4's `str | dict[str, str]` candidate contract: their exact shape and
  value types are derived from the seed and enforced for every proposal. A
  pinned-compatible `:batch_evaluator` may replace or accompany the scalar
  evaluator when an evaluation backend needs all pending candidate/example
  pairs in one ordered call.
  """

  # These structs remain internal execution values for the independent GEPA
  # artifact optimizer and evaluator normalization. They are not part of the
  # Optimize Anything public surface.
  defmodule Artifact do
    @moduledoc false
    defstruct [:id, :kind, :text, parameters: %{}, metadata: %{}]
  end

  defmodule Evaluation do
    @moduledoc false
    defstruct score: 0.0, diagnostics: [], metadata: %{}
  end

  alias Imp.Optimize.Anything.{Result, Runner}
  alias Imp.Optimizer.Artifact, as: OptimizerArtifact

  @doc "Runs Optimize Anything for a text or JSON-safe structured seed and returns a Result."
  @spec run(String.t() | map() | nil, function() | nil, keyword()) :: struct()
  def run(seed_candidate, evaluator, opts \\ [])

  def run(seed_candidate, evaluator, opts)
      when (is_binary(seed_candidate) or is_map(seed_candidate) or is_nil(seed_candidate)) and
             (is_function(evaluator) or is_nil(evaluator)) and is_list(opts) do
    Runner.run(seed_candidate, evaluator, opts)
  end

  def run(seed_candidate, evaluator, opts) do
    raise ArgumentError,
          "Imp.Optimize.Anything.run/3 expects a text/named/structured seed, evaluator function or nil, and keyword options; got: " <>
            "#{inspect(seed_candidate)}, #{inspect(evaluator)}, #{inspect(opts)}"
  end

  @doc "Returns the validation-selected candidate from an Optimize Anything result."
  @spec best_candidate(struct()) :: map() | String.t()
  def best_candidate(%Result{} = result), do: Result.best_candidate(result)

  @doc """
  Exports an existing Optimize Anything result as a portable value artifact.

  Export is pure: it preserves the result's candidate order, validation scores,
  and selected champion without invoking an evaluator, proposer, or selector.
  Values must already be canonical JSON so a fresh VM can restore them without
  creating atoms or loading executable code.
  """
  @spec to_artifact(struct(), keyword()) :: Imp.Optimizer.Artifact.artifact()
  def to_artifact(result, opts \\ [])

  def to_artifact(%Result{} = result, opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_artifact_options!(opts)
    unknown = Keyword.keys(opts) -- [:provenance]

    if unknown != [],
      do: raise(ArgumentError, "unknown Optimize Anything artifact options: #{inspect(unknown)}")

    unless length(result.candidates) == length(result.validation_scores) do
      raise ArgumentError,
            "Optimize Anything result candidates and validation scores are misaligned"
    end

    champion_index = Result.best_index(result)
    report = Result.to_map(result)

    candidates =
      result.candidates
      |> Enum.zip(result.validation_scores)
      |> Enum.with_index()
      |> Enum.map(fn {{value, score}, index} ->
        OptimizerArtifact.value_candidate(candidate_id(index), value,
          score: score,
          report: if(index == champion_index, do: report),
          metadata: %{
            "candidate_index" => index,
            "discovered_at_metric_call" => Enum.at(result.discovery_evaluation_counts, index),
            "parent_indexes" => Enum.at(result.parents, index, [])
          }
        )
      end)

    champion = Enum.fetch!(candidates, champion_index)
    challengers = List.delete_at(candidates, champion_index)
    OptimizerArtifact.new(champion, challengers, provenance: Keyword.get(opts, :provenance, %{}))
  end

  def to_artifact(result, opts) do
    raise ArgumentError,
          "Optimize Anything to_artifact/2 expects a Result and keyword options, got: #{inspect({result, opts})}"
  end

  @doc """
  Exports structured component candidates onto a trusted program Artifact.

  Each Optimize Anything candidate must be the complete map returned by
  `Imp.ProgramParameters.values/1`. Values are validated and applied through
  the program's component contract before the parameter-only candidate is
  created. Runtime callbacks, tools, clients, and credentials remain in the
  supplied trusted program and are never serialized.
  """
  @spec to_program_artifact(struct(), struct(), keyword()) :: Imp.Optimizer.Artifact.artifact()
  def to_program_artifact(result, program, opts \\ [])

  def to_program_artifact(%Result{} = result, %_module{} = program, opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_artifact_options!(opts)
    unknown = Keyword.keys(opts) -- [:provenance]

    if unknown != [],
      do:
        raise(
          ArgumentError,
          "unknown Optimize Anything program artifact options: #{inspect(unknown)}"
        )

    unless length(result.candidates) == length(result.validation_scores) do
      raise ArgumentError,
            "Optimize Anything result candidates and validation scores are misaligned"
    end

    champion_index = Result.best_index(result)
    report = Result.to_map(result)

    candidates =
      result.candidates
      |> Enum.zip(result.validation_scores)
      |> Enum.with_index()
      |> Enum.map(fn {{values, score}, index} ->
        unless is_map(values) and not is_struct(values) do
          raise ArgumentError,
                "Optimize Anything program candidates must be complete component-value maps"
        end

        selected = Imp.ProgramParameters.apply_values!(program, values)

        OptimizerArtifact.parameter_candidate(candidate_id(index), selected,
          score: score,
          report: if(index == champion_index, do: report),
          metadata: %{
            "candidate_index" => index,
            "discovered_at_metric_call" => Enum.at(result.discovery_evaluation_counts, index),
            "parent_indexes" => Enum.at(result.parents, index, [])
          }
        )
      end)

    champion = Enum.fetch!(candidates, champion_index)
    challengers = List.delete_at(candidates, champion_index)
    OptimizerArtifact.new(champion, challengers, provenance: Keyword.get(opts, :provenance, %{}))
  end

  def to_program_artifact(result, program, opts) do
    raise ArgumentError,
          "Optimize Anything to_program_artifact/3 expects a Result, trusted program struct, and keyword options, got: #{inspect({result, program, opts})}"
  end

  @doc false
  def validate_resume_state(nil), do: {:ok, nil}
  def validate_resume_state(state) when is_map(state), do: {:ok, state}

  def validate_resume_state(state),
    do: {:error, "expected nil or a resume-state map, got: #{inspect(state)}"}

  @doc false
  def validate_checkpoint_fn(nil), do: {:ok, nil}

  def validate_checkpoint_fn(checkpoint_fn) when is_function(checkpoint_fn, 1),
    do: {:ok, checkpoint_fn}

  def validate_checkpoint_fn(checkpoint_fn),
    do: {:error, "expected nil or an arity-1 function, got: #{inspect(checkpoint_fn)}"}

  defp candidate_id(index),
    do: "candidate-" <> String.pad_leading(Integer.to_string(index), 4, "0")

  defp invalid_artifact_options!(opts),
    do:
      raise(
        ArgumentError,
        "Optimize Anything artifact options must be a keyword list, got: #{inspect(opts)}"
      )
end
