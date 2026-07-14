defmodule Imp.Optimizer.GEPA.Acceptance do
  @moduledoc """
  Pure acceptance policies for GEPA candidate proposals.

  Reflective mutations use strict improvement, matching GEPA's minibatch gate.
  Merges use equal-or-better acceptance so a merge may preserve the stronger
  parent's score while combining independently useful components.

  Custom callbacks receive a context containing the complete `before` and
  `after` `Imp.Optimizer.GEPA.Result` values as well as score summaries. This
  keeps objective scores, outputs, trajectories, side information, proposal
  metadata, and engine state available to application-specific policies.
  """

  alias Imp.Optimizer.GEPA.Result

  @type operation :: :mutation | :merge
  @type decision :: :accept | :reject
  @type callback_decision ::
          boolean() | decision() | {:accept | :reject, term()}
  @type callback :: (context() -> callback_decision())
  @type policy :: :strict_improvement | :equal_or_better | {:callback, callback()}
  @type context :: %{
          required(:operation) => operation() | atom(),
          required(:before) => Result.t(),
          required(:after) => Result.t(),
          required(:before_score) => number(),
          required(:after_score) => number(),
          required(:before_scores) => [number()],
          required(:after_scores) => [number()],
          optional(atom()) => term()
        }

  @doc "Returns the source-faithful default policy for an operation."
  @spec default(operation()) :: policy()
  def default(:mutation), do: :strict_improvement
  def default(:merge), do: :equal_or_better

  @doc "Builds a custom acceptance policy."
  @spec callback(callback()) :: policy()
  def callback(fun) when is_function(fun, 1), do: {:callback, fun}

  @doc "Returns whether a proposal is accepted, discarding decision detail."
  @spec accept?(policy(), Result.t(), Result.t(), map()) :: boolean()
  def accept?(policy, before_result, after_result, context \\ %{}) do
    match?({:accept, _detail}, decide(policy, before_result, after_result, context))
  end

  @doc "Evaluates a policy and returns a normalized decision with its detail."
  @spec decide(policy(), Result.t(), Result.t(), map()) ::
          {:accept | :reject, term()}
  def decide(policy, before_result, after_result, context \\ %{})

  def decide(policy, %Result{} = before_result, %Result{} = after_result, context)
      when is_map(context) do
    callback_context = context(before_result, after_result, context, policy)

    case policy do
      :strict_improvement ->
        compare(callback_context, :strict_improvement)

      :equal_or_better ->
        compare(callback_context, :equal_or_better)

      {:callback, fun} when is_function(fun, 1) ->
        fun.(callback_context) |> normalize_decision!()

      invalid ->
        raise ArgumentError, "invalid GEPA acceptance policy: #{inspect(invalid)}"
    end
  end

  defp context(before_result, after_result, supplied, policy) do
    operation = Map.get(supplied, :operation, operation_for_policy(policy))

    Map.merge(supplied, %{
      operation: operation,
      before: before_result,
      after: after_result,
      before_score: Enum.sum(before_result.scores),
      after_score: Enum.sum(after_result.scores),
      before_scores: before_result.scores,
      after_scores: after_result.scores
    })
  end

  defp operation_for_policy(:strict_improvement), do: :mutation
  defp operation_for_policy(:equal_or_better), do: :merge
  defp operation_for_policy({:callback, _callback}), do: :custom

  defp compare(%{before_score: before_score, after_score: after_score}, :strict_improvement) do
    if after_score > before_score,
      do: {:accept, :strict_improvement},
      else: {:reject, :no_strict_improvement}
  end

  defp compare(%{before_score: before_score, after_score: after_score}, :equal_or_better) do
    if after_score >= before_score,
      do: {:accept, :equal_or_better},
      else: {:reject, :worse_score}
  end

  defp normalize_decision!(true), do: {:accept, true}
  defp normalize_decision!(:accept), do: {:accept, :accept}
  defp normalize_decision!({:accept, detail}), do: {:accept, detail}
  defp normalize_decision!(false), do: {:reject, false}
  defp normalize_decision!(:reject), do: {:reject, :reject}
  defp normalize_decision!({:reject, detail}), do: {:reject, detail}

  defp normalize_decision!(decision) do
    raise ArgumentError,
          "GEPA acceptance callback must return a boolean, :accept, :reject, " <>
            "{:accept, detail}, or {:reject, detail}; got: #{inspect(decision)}"
  end
end
