defmodule DSEx.Predict.Refine do
  @moduledoc "Iteratively call a program until a metric passes or attempts are exhausted."

  defstruct [:program, :metric, :feedback_fn, max_attempts: 3]

  def new(program, metric, opts \\ []),
    do: %__MODULE__{
      program: program,
      metric: metric,
      feedback_fn: Keyword.get(opts, :feedback_fn),
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    }

  def call(%__MODULE__{} = refine, inputs) do
    Enum.reduce_while(attempts(refine.max_attempts), {:error, :no_attempts, []}, fn attempt,
                                                                                    {_status,
                                                                                     _last,
                                                                                     history} ->
      inputs = maybe_add_hint(inputs, refine.feedback_fn, history)

      case DSEx.Module.call(refine.program, inputs) do
        {:ok, prediction} = ok ->
          history = history ++ [%{attempt: attempt, prediction: prediction}]

          if refine.metric.(%DSEx.Example{}, prediction) |> DSEx.Metrics.pass?(),
            do: {:halt, ok},
            else: {:cont, {:ok, prediction, history}}

        error ->
          {:cont, {elem(error, 0), elem(error, 1), history}}
      end
    end)
    |> case do
      {:ok, prediction, history} ->
        {:ok, DSEx.Prediction.put(prediction, :refine_history, history)}

      other ->
        other
    end
  end

  defp attempts(max_attempts) when is_integer(max_attempts) and max_attempts > 0,
    do: 1..max_attempts

  defp attempts(_max_attempts), do: []

  defp maybe_add_hint(inputs, nil, _history), do: inputs
  defp maybe_add_hint(inputs, _feedback_fn, []), do: inputs

  defp maybe_add_hint(inputs, feedback_fn, history) do
    inputs
    |> Map.new()
    |> Map.put(:hint_, feedback_fn.(history))
  end
end
