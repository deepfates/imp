defmodule DSEx.Optimize.Anything do
  @moduledoc """
  Optimizes text and named-component systems against evaluator feedback.

  `DSEx.Optimize.Anything.Config` controls reflection, budgets, selection,
  caching, merging, stopping, and tracking. Runs return the immutable
  `DSEx.Optimize.Anything.Result` contract.
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

  alias DSEx.Optimize.Anything.Runner

  @doc "Runs the canonical Optimize Anything engine and returns a Result."
  @spec run(String.t() | map() | nil, function(), keyword()) :: DSEx.Optimize.Anything.Result.t()
  def run(seed_candidate, evaluator, opts \\ [])

  def run(seed_candidate, evaluator, opts)
      when (is_binary(seed_candidate) or is_map(seed_candidate) or is_nil(seed_candidate)) and
             is_function(evaluator) and is_list(opts) do
    Runner.run(seed_candidate, evaluator, opts)
  end

  def run(seed_candidate, evaluator, opts) do
    raise ArgumentError,
          "DSEx.Optimize.Anything.run/3 expects a text/named seed, evaluator function, and keyword options; got: " <>
            "#{inspect(seed_candidate)}, #{inspect(evaluator)}, #{inspect(opts)}"
  end
end
