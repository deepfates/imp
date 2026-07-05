defmodule DSPy.Teleprompt.BetterTogether do
  @moduledoc "Meta-optimizer that applies named prompt/weight optimizers in sequence."

  defstruct [:metric, optimizers: %{}]

  def new(metric, optimizers \\ %{}) do
    optimizers =
      if map_size(Map.new(optimizers)) == 0 do
        %{
          p: DSPy.Teleprompt.RandomSearch.new(metric),
          w: DSPy.Teleprompt.BootstrapFinetune.new(metric)
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
      optimizer = Map.fetch!(bt.optimizers, String.to_atom(key))
      compile_step(optimizer, program, trainset, valset)
    end)
  end

  defp compile_step(%DSPy.Teleprompt.BootstrapFinetune{} = optimizer, program, trainset, _valset) do
    case DSPy.Teleprompt.BootstrapFinetune.compile(optimizer, program, trainset) do
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
end
