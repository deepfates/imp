defmodule DSEx.Predict.BestOfN do
  @moduledoc "Run a program multiple times and keep the prediction with the highest metric score."

  defstruct [:program, :metric, :feedback_fn, n: 3]

  def new(program, metric, opts \\ []),
    do: %__MODULE__{
      program: program,
      metric: metric,
      n: Keyword.get(opts, :n, 3),
      feedback_fn: Keyword.get(opts, :feedback_fn)
    }

  def call(%__MODULE__{} = best, inputs) do
    1..best.n
    |> Enum.map(fn _ -> best.program.__struct__.call(best.program, inputs) end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, prediction} -> prediction end)
    |> case do
      [] ->
        {:error, :no_successful_predictions}

      predictions ->
        {:ok,
         predictions
         |> Enum.max_by(&score(best.metric, &1))
         |> attach_feedback(best.feedback_fn, predictions)}
    end
  end

  defp score(metric, prediction) do
    case metric.(%DSEx.Example{}, prediction) do
      true -> 1.0
      false -> 0.0
      value when is_number(value) -> value
    end
  end

  defp attach_feedback(prediction, nil, _predictions), do: prediction

  defp attach_feedback(prediction, feedback_fn, predictions),
    do: DSEx.Prediction.put(prediction, :feedback, feedback_fn.(predictions))
end
