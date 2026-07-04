defmodule DSPy.Predict.Refine do
  @moduledoc "Iteratively call a program until a metric passes or attempts are exhausted."

  defstruct [:program, :metric, max_attempts: 3]

  def new(program, metric, opts \\ []),
    do: %__MODULE__{
      program: program,
      metric: metric,
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    }

  def call(%__MODULE__{} = refine, inputs) do
    Enum.reduce_while(1..refine.max_attempts, {:error, :no_attempts}, fn _attempt, _last ->
      case refine.program.__struct__.call(refine.program, inputs) do
        {:ok, prediction} = ok ->
          if refine.metric.(%DSPy.Example{}, prediction), do: {:halt, ok}, else: {:cont, ok}

        error ->
          {:cont, error}
      end
    end)
  end
end
