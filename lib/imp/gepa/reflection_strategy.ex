defmodule Imp.GEPA.ReflectionStrategy do
  @moduledoc """
  Public behaviour for trusted custom GEPA reflection strategies.

  Implement `reflect/3` for a stateless strategy. For durable contextual state,
  implement `reflect/4`, `dump_state/1`, and `load_state/1`, then wrap the
  module and initial context with `contextual/2`. Checkpoints retain validated
  data and module identity; they never serialize executable code.
  """

  @type proposal :: map()
  @type candidate :: map()
  @type component_name :: atom()
  @type job :: {candidate(), map(), [component_name()]}

  @callback reflect(candidate(), map(), [component_name()]) :: proposal()
  @callback reflect(candidate(), map(), [component_name()], term()) ::
              {proposal(), term()} | {:ok, proposal(), term()} | {:error, term()} | proposal()
  @callback reflect_many([job()], term()) ::
              {[proposal()], term()} | {:ok, [proposal()], term()} | {:error, term()}
  @callback total_cost(term()) :: number()
  @callback dump_state(term()) :: term()
  @callback load_state(term()) :: term()
  @optional_callbacks reflect: 3,
                      reflect_many: 2,
                      total_cost: 1,
                      dump_state: 1,
                      load_state: 1

  @doc "Builds a durable contextual strategy from a trusted behaviour module."
  @spec contextual(module(), term()) :: struct()
  def contextual(module, context) do
    Imp.Optimizer.GEPA.ReflectionStrategy.contextual(module, context)
  end
end
