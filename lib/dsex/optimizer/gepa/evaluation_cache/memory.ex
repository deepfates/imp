defmodule DSEx.Optimizer.GEPA.EvaluationCache.Memory do
  @moduledoc """
  In-memory backend for GEPA evaluation entries.

  This implementation delegates identity, validation, and assembly to the
  existing immutable `DSEx.Optimizer.GEPA.EvaluationCache` module.
  """

  @behaviour DSEx.Optimizer.GEPA.EvaluationCache.Backend

  alias DSEx.Optimizer.GEPA.EvaluationCache

  defstruct entries: %{}

  @type t :: %__MODULE__{entries: EvaluationCache.t()}

  @spec new(EvaluationCache.t()) :: t()
  def new(entries \\ %{}) when is_map(entries), do: %__MODULE__{entries: entries}

  @impl true
  def lookup(%__MODULE__{entries: entries}, candidate, examples),
    do: EvaluationCache.lookup(entries, candidate, examples)

  @impl true
  def put(%__MODULE__{entries: entries} = cache, candidate, examples, result) do
    %{cache | entries: EvaluationCache.put(entries, candidate, examples, result)}
  end

  @impl true
  def assemble(examples, hits, missing_indexes, missing_result),
    do: EvaluationCache.assemble(examples, hits, missing_indexes, missing_result)
end
