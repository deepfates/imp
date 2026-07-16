defmodule Imp.Optimizer.GEPA.ProposalSelection do
  @moduledoc false

  @type strategy ::
          :all_improvements
          | :best_improvement
          | {:top_k, pos_integer()}
          | {:callback, function()}

  def validate!(:all_improvements), do: :ok
  def validate!(:best_improvement), do: :ok
  def validate!({:top_k, k}) when is_integer(k) and k > 0, do: :ok
  def validate!({:callback, callback}) when is_function(callback, 3), do: :ok

  def validate!(strategy) do
    raise ArgumentError,
          ":selection_strategy must be :all_improvements, :best_improvement, " <>
            "{:top_k, positive_integer}, or {:callback, arity_3_function}; got: #{inspect(strategy)}"
  end

  def select(:all_improvements, proposals, _state, verdicts) do
    Enum.filter(proposals, &accepted?(&1, verdicts))
  end

  def select(:best_improvement, proposals, _state, verdicts) do
    proposals
    |> Enum.filter(&accepted?(&1, verdicts))
    |> Enum.max_by(& &1.margin, fn -> nil end)
    |> List.wrap()
  end

  def select({:top_k, k}, proposals, _state, verdicts) do
    proposals
    |> Enum.filter(&accepted?(&1, verdicts))
    |> Enum.sort_by(& &1.margin, :desc)
    |> Enum.take(k)
  end

  def select({:callback, callback}, proposals, state, verdicts) do
    criterion = fn proposal -> accepted?(proposal, verdicts) end
    selected = callback.(proposals, state, criterion)

    unless is_list(selected) do
      raise ArgumentError, "GEPA selection callback must return a list of input proposals"
    end

    input_by_slot = Map.new(proposals, &{&1.slot, &1})

    selected
    |> Enum.flat_map(fn
      proposal when is_map(proposal) ->
        case Map.fetch(proposal, :slot) do
          {:ok, slot} ->
            case Map.fetch(input_by_slot, slot) do
              {:ok, ^proposal} -> [proposal]
              _foreign_or_modified -> []
            end

          :error ->
            []
        end

      _foreign ->
        []
    end)
  end

  defp accepted?(proposal, verdicts),
    do: match?({:accept, _}, Map.fetch!(verdicts, proposal.slot))
end
