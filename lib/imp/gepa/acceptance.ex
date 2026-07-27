defmodule Imp.GEPA.Acceptance do
  @moduledoc """
  Public constructors and evaluators for GEPA candidate acceptance policies.

  The built-in policies compare aggregate candidate scores. Custom callbacks
  receive the complete before/after result context and must return a documented
  accept or reject decision.
  """

  @type decision :: :accept | :reject
  @type callback_decision :: boolean() | decision() | {decision(), term()}
  @type callback :: (map() -> callback_decision())
  @type policy :: :strict_improvement | :equal_or_better | {:callback, callback()}

  @doc "Returns the built-in policy for a mutation or merge."
  @spec default(:mutation | :merge) :: policy()
  defdelegate default(operation), to: Imp.Optimizer.GEPA.Acceptance

  @doc "Builds a custom acceptance policy."
  @spec callback(callback()) :: policy()
  defdelegate callback(fun), to: Imp.Optimizer.GEPA.Acceptance

  @doc "Returns whether the policy accepts the proposed result."
  @spec accept?(policy(), struct(), struct(), map()) :: boolean()
  defdelegate accept?(policy, before_result, after_result, context \\ %{}),
    to: Imp.Optimizer.GEPA.Acceptance

  @doc "Evaluates a policy and returns its normalized decision and detail."
  @spec decide(policy(), struct(), struct(), map()) :: {decision(), term()}
  defdelegate decide(policy, before_result, after_result, context \\ %{}),
    to: Imp.Optimizer.GEPA.Acceptance
end
