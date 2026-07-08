defmodule DSEx.Predict.BestOfN do
  @moduledoc "Run a program multiple times and keep the prediction with the highest metric score."

  defstruct [:program, :metric, :feedback_fn, n: 3]

  @option_schema [
    n: [type: :non_neg_integer, default: 3],
    feedback_fn: [
      type: {:custom, __MODULE__, :validate_feedback_fn, []},
      default: nil
    ]
  ]

  def new(program, metric, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.BestOfN.new/3")
    validate_metric!(metric)

    %__MODULE__{
      program: program,
      metric: metric,
      n: opts[:n],
      feedback_fn: opts[:feedback_fn]
    }
  end

  def validate_feedback_fn(nil), do: {:ok, nil}
  def validate_feedback_fn(feedback_fn) when is_function(feedback_fn, 1), do: {:ok, feedback_fn}

  def validate_feedback_fn(feedback_fn) do
    {:error, "expected nil or a unary function, got: #{inspect(feedback_fn)}"}
  end

  def call(%__MODULE__{} = best, inputs) do
    attempts = attempts(best.n)

    results =
      attempts
      |> Enum.map(fn attempt -> {attempt, DSEx.Module.call(best.program, inputs)} end)

    results
    |> Enum.filter(fn {_attempt, result} -> match?({:ok, _}, result) end)
    |> Enum.map(fn {_attempt, {:ok, prediction}} -> prediction end)
    |> case do
      [] ->
        {:error, no_successful_predictions_error(attempts, results)}

      predictions ->
        {:ok,
         predictions
         |> Enum.max_by(&score(best.metric, &1).score)
         |> attach_feedback(best.feedback_fn, predictions)}
    end
  end

  defp attempts(n) when is_integer(n) and n > 0, do: 1..n
  defp attempts(_n), do: []

  defp no_successful_predictions_error([], _results), do: :no_successful_predictions

  defp no_successful_predictions_error(_attempts, results) do
    errors =
      Enum.map(results, fn
        {attempt, {:error, reason}} -> %{attempt: attempt, error: reason}
        {attempt, other} -> %{attempt: attempt, error: {:invalid_module_result, inspect(other)}}
      end)

    {:no_successful_predictions, errors}
  end

  defp validate_metric!(metric) when is_function(metric, 2), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Predict.BestOfN.new/3 expects a metric function with arity 2; got: #{inspect(metric)}"
  end

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
