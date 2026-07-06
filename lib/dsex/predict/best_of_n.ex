defmodule DSEx.Predict.BestOfN do
  @moduledoc "Run a program multiple times and keep the prediction with the highest metric score."

  defstruct [:program, :metric, n: 3]

  def new(program, metric, opts \\ []),
    do: %__MODULE__{program: program, metric: metric, n: Keyword.get(opts, :n, 3)}

  def call(%__MODULE__{} = best, inputs) do
    1..best.n
    |> Enum.map(fn _ -> best.program.__struct__.call(best.program, inputs) end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, prediction} -> prediction end)
    |> case do
      [] -> {:error, :no_successful_predictions}
      predictions -> {:ok, Enum.max_by(predictions, &best.metric.(%DSEx.Example{}, &1))}
    end
  end
end
