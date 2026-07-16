defmodule Imp.Optimize.Anything do
  @moduledoc """
  Optimizes text and named-component systems against evaluator feedback.

  The `run/3` surface controls reflection, budgets, selection, caching,
  merging, stopping, and tracking through its options. It returns an immutable
  result value.
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

  alias Imp.Optimize.Anything.Runner

  @doc "Runs the canonical Optimize Anything engine and returns a Result."
  @spec run(String.t() | map() | nil, function(), keyword()) :: struct()
  def run(seed_candidate, evaluator, opts \\ [])

  def run(seed_candidate, evaluator, opts)
      when (is_binary(seed_candidate) or is_map(seed_candidate) or is_nil(seed_candidate)) and
             is_function(evaluator) and is_list(opts) do
    Runner.run(seed_candidate, evaluator, opts)
  end

  def run(seed_candidate, evaluator, opts) do
    raise ArgumentError,
          "Imp.Optimize.Anything.run/3 expects a text/named seed, evaluator function, and keyword options; got: " <>
            "#{inspect(seed_candidate)}, #{inspect(evaluator)}, #{inspect(opts)}"
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
end
