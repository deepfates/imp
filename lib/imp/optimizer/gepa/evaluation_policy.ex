defmodule Imp.Optimizer.GEPA.EvaluationPolicy do
  @moduledoc """
  Validation policy contract for the GEPA engine.

  Policies choose validation example indexes for each candidate and own the
  definition of best candidate and reported validation score. `:full` resolves
  to the source-default policy that evaluates every example in order.
  """

  @type candidate_entry :: struct()

  @callback validation_ids([term()], struct() | nil, non_neg_integer() | nil) ::
              [non_neg_integer()]
  @callback best_entry([candidate_entry()]) :: candidate_entry()
  @callback score(candidate_entry()) :: number()

  defmodule Full do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.EvaluationPolicy

    @impl true
    def validation_ids(valset, _state, _target_candidate_id),
      do: indexes(length(valset))

    @impl true
    def best_entry(entries) do
      Enum.max_by(entries, fn entry ->
        {entry.validation.aggregate_score, length(entry.validation.scores), -entry.id}
      end)
    end

    @impl true
    def score(entry), do: entry.validation.aggregate_score

    defp indexes(0), do: []
    defp indexes(size), do: Enum.to_list(0..(size - 1))
  end

  @doc "Resolves and validates a policy name or behaviour module."
  @spec resolve!(:full | module()) :: module()
  def resolve!(:full), do: Full

  def resolve!(module) when is_atom(module) do
    required = [validation_ids: 3, best_entry: 1, score: 1]

    if Code.ensure_loaded?(module) and
         Enum.all?(required, fn {function, arity} ->
           function_exported?(module, function, arity)
         end) do
      module
    else
      raise ArgumentError,
            "GEPA evaluation policy must implement validation_ids/3, best_entry/1, and score/1"
    end
  end

  def resolve!(policy) do
    raise ArgumentError,
          "GEPA evaluation policy must be :full or a module, got: #{inspect(policy)}"
  end

  @doc false
  def validation_ids(policy, valset, state, target_candidate_id) do
    ids = policy.validation_ids(valset, state, target_candidate_id)

    unless is_list(ids) and ids != [] and Enum.all?(ids, &valid_id?(&1, length(valset))) and
             length(Enum.uniq(ids)) == length(ids) do
      raise ArgumentError,
            "GEPA evaluation policy must return unique validation indexes within the valset"
    end

    ids
  end

  defp valid_id?(id, size), do: is_integer(id) and id >= 0 and id < size
end
