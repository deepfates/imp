defmodule Imp.Optimizer.GEPA.ModuleSelector do
  @moduledoc """
  Component-selection contract for reflective GEPA mutations.

  A custom selector may be an arity-five function, a module implementing
  `select_modules/5`, or a struct whose module implements `select_modules/6`.
  The functions and callbacks receive the
  engine state, captured trajectories, minibatch scores, candidate index, and
  complete candidate, and must return a non-empty list of candidate components.
  """

  alias Imp.Optimizer.GEPA.{Candidate, Engine}

  @type components :: [Candidate.component_name()]

  @callback select_modules(
              Engine.State.t(),
              map(),
              [number()],
              non_neg_integer(),
              Candidate.t()
            ) :: components()
  @callback select_modules(
              struct(),
              Engine.State.t(),
              map(),
              [number()],
              non_neg_integer(),
              Candidate.t()
            ) :: components()
  @optional_callbacks select_modules: 5, select_modules: 6

  @built_ins [:round_robin, :all]

  @doc false
  @spec validate!(term()) :: :ok
  def validate!(selector) when selector in @built_ins, do: :ok

  def validate!(selector) when is_function(selector, 5), do: :ok

  def validate!(selector) when is_function(selector) do
    raise ArgumentError,
          ":module_selector functions must take (state, trajectories, scores, candidate_idx, candidate), " <>
            "got a function of arity #{arity(selector)}"
  end

  def validate!(%module{} = selector) do
    ensure_callback!(module, :select_modules, 6, selector)
  end

  def validate!(module) when is_atom(module) do
    ensure_callback!(module, :select_modules, 5, module)
  end

  def validate!(selector) do
    raise ArgumentError,
          ":module_selector must be :round_robin, :all, an arity-five function, a selector module, " <>
            "or a selector struct, got: " <> inspect(selector)
  end

  @doc false
  @spec select(term(), Engine.State.t(), map(), [number()], non_neg_integer(), Candidate.t()) ::
          components()
  def select(selector, %Engine.State{} = state, trajectories, scores, candidate_idx, candidate)
      when is_map(trajectories) and is_list(scores) and is_integer(candidate_idx) and
             is_map(candidate) do
    components = invoke(selector, state, trajectories, scores, candidate_idx, candidate)
    validate_result!(components, candidate)
  end

  @doc false
  @spec component_order(Candidate.t()) :: components()
  def component_order(candidate) when is_map(candidate) do
    Enum.sort_by(Map.keys(candidate), &inspect/1)
  end

  defp invoke(:round_robin, state, _trajectories, _scores, candidate_idx, candidate) do
    entry = Enum.find(state.candidates, &(&1.id == candidate_idx))

    if is_nil(entry) do
      raise ArgumentError,
            "GEPA module selector received unknown candidate index: #{inspect(candidate_idx)}"
    end

    components = component_order(candidate)
    [Enum.at(components, rem(entry.next_component, length(components)))]
  end

  defp invoke(:all, _state, _trajectories, _scores, _candidate_idx, candidate),
    do: component_order(candidate)

  defp invoke(selector, state, trajectories, scores, candidate_idx, candidate)
       when is_function(selector, 5) do
    selector.(state, trajectories, scores, candidate_idx, candidate)
  end

  defp invoke(%module{} = selector, state, trajectories, scores, candidate_idx, candidate) do
    module.select_modules(selector, state, trajectories, scores, candidate_idx, candidate)
  end

  defp invoke(module, state, trajectories, scores, candidate_idx, candidate) do
    module.select_modules(state, trajectories, scores, candidate_idx, candidate)
  end

  defp validate_result!(components, candidate) when is_list(components) and components != [] do
    candidate_components = MapSet.new(Map.keys(candidate))

    cond do
      length(Enum.uniq(components)) != length(components) ->
        raise ArgumentError, "GEPA module selector returned duplicate components"

      unknown = Enum.find(components, &(not MapSet.member?(candidate_components, &1))) ->
        raise ArgumentError,
              "GEPA module selector returned unknown component: #{inspect(unknown)}"

      true ->
        components
    end
  end

  defp validate_result!(result, _candidate) do
    raise ArgumentError,
          "GEPA module selector must return a non-empty list of candidate components, got: " <>
            inspect(result)
  end

  defp arity(fun) do
    {:arity, arity} = Function.info(fun, :arity)
    arity
  end

  defp ensure_callback!(module, function, arity, selector) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, arity) do
      :ok
    else
      raise ArgumentError,
            "GEPA module selector #{inspect(selector)} must implement #{function}/#{arity}"
    end
  end
end
