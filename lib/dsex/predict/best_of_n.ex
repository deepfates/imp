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
    attempts(best.n)
    |> Enum.map(fn _ -> DSEx.Module.call(best.program, inputs) end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, prediction} -> prediction end)
    |> case do
      [] ->
        {:error, :no_successful_predictions}

      predictions ->
        {:ok,
         predictions
         |> Enum.max_by(&score(best.metric, &1).score)
         |> attach_feedback(best.feedback_fn, predictions)}
    end
  end

  defp attempts(n) when is_integer(n) and n > 0, do: 1..n
  defp attempts(_n), do: []

  defp score(metric, prediction) do
    metric
    |> apply([%DSEx.Example{}, prediction])
    |> DSEx.Metrics.normalize_result()
  rescue
    error ->
      %DSEx.Metrics.Result{
        feedback: {:metric_error, error_message(error)},
        metadata: %{error: error}
      }
  catch
    kind, reason ->
      %DSEx.Metrics.Result{
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{error: {kind, reason}}
      }
  end

  defp attach_feedback(prediction, nil, _predictions), do: prediction

  defp attach_feedback(prediction, feedback_fn, predictions),
    do: DSEx.Prediction.put(prediction, :feedback, safe_feedback(feedback_fn, predictions))

  defp safe_feedback(feedback_fn, predictions) do
    feedback_fn.(predictions)
  rescue
    error -> {:feedback_error, error_message(error)}
  catch
    kind, reason -> {:feedback_error, error_message({kind, reason})}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
