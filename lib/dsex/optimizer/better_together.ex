defmodule DSEx.Optimizer.BetterTogether do
  @moduledoc "Meta-optimizer that applies named prompt/weight optimizers in sequence."

  defstruct [:metric, optimizers: %{}]

  def new(metric, optimizers \\ %{}) do
    optimizers =
      if map_size(Map.new(optimizers)) == 0 do
        %{
          p: DSEx.Optimizer.RandomSearch.new(metric),
          w: DSEx.Optimizer.BootstrapFinetune.new(metric)
        }
      else
        Map.new(optimizers)
      end

    %__MODULE__{metric: metric, optimizers: optimizers}
  end

  def compile(%__MODULE__{} = bt, student, trainset, valset, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, "p")

    strategy
    |> String.split("->")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(student, fn key, program ->
      optimizer = fetch_optimizer!(bt.optimizers, key)
      compile_step(optimizer, program, trainset, valset)
    end)
  end

  defp compile_step(
         %DSEx.Optimizer.BootstrapFinetune{} = optimizer,
         program,
         trainset,
         _valset
       ) do
    case DSEx.Optimizer.BootstrapFinetune.compile(optimizer, program, trainset) do
      %{program: compiled} -> compiled
      _other -> program
    end
  end

  defp compile_step(optimizer, program, trainset, valset) do
    cond do
      function_exported?(optimizer.__struct__, :compile, 4) ->
        optimizer.__struct__.compile(optimizer, program, trainset, valset)

      function_exported?(optimizer.__struct__, :compile, 3) ->
        optimizer.__struct__.compile(optimizer, program, trainset)

      true ->
        program
    end
  end

  defp fetch_optimizer!(optimizers, key) do
    cond do
      Map.has_key?(optimizers, key) ->
        Map.fetch!(optimizers, key)

      is_atom(existing_atom_or_string(key)) and
          Map.has_key?(optimizers, existing_atom_or_string(key)) ->
        Map.fetch!(optimizers, existing_atom_or_string(key))

      true ->
        raise KeyError, key: key, term: optimizers
    end
  end

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
