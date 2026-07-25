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
end
