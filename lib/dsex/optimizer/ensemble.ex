defmodule DSEx.Optimizer.Ensemble.Program do
  @moduledoc false
  @behaviour DSEx.Module

  defstruct [:ensemble, programs: []]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    programs =
      cond do
        program.ensemble.deterministic ->
          Enum.take(program.programs, program.ensemble.size || length(program.programs))

        program.ensemble.size ->
          program.programs |> Enum.shuffle() |> Enum.take(program.ensemble.size)

        true ->
          program.programs
      end

    outputs = Enum.map(programs, &DSEx.Module.call(&1, inputs))

    if program.ensemble.reduce_fn do
      predictions =
        Enum.flat_map(outputs, fn
          {:ok, pred} -> [pred]
          _ -> []
        end)

      {:ok, program.ensemble.reduce_fn.(predictions)}
    else
      {:ok, DSEx.Prediction.new(%{outputs: outputs})}
    end
  end
end

defmodule DSEx.Optimizer.Ensemble do
  @moduledoc "Compile multiple programs into an ensemble program."

  defstruct reduce_fn: nil, size: nil, deterministic: false

  def new(opts \\ []) do
    %__MODULE__{
      reduce_fn: Keyword.get(opts, :reduce_fn),
      size: Keyword.get(opts, :size),
      deterministic: Keyword.get(opts, :deterministic, false)
    }
  end

  def compile(%__MODULE__{} = ensemble, programs),
    do: %DSEx.Optimizer.Ensemble.Program{programs: programs, ensemble: ensemble}
end
