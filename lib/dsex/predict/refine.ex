defmodule DSEx.Predict.Refine do
  @moduledoc "Iteratively call a program until a metric passes or attempts are exhausted."

  defstruct [:program, :metric, :feedback_fn, max_attempts: 3]

  @option_schema [
    feedback_fn: [type: :any, default: nil],
    max_attempts: [type: :non_neg_integer, default: 3]
  ]

  def new(program, metric, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Refine.new/3")
    validate_metric!(metric)
    validate_feedback_fn!(opts[:feedback_fn])

    %__MODULE__{
      program: program,
      metric: metric,
      feedback_fn: opts[:feedback_fn],
      max_attempts: opts[:max_attempts]
    }
  end

  def call(%__MODULE__{} = refine, inputs) do
    Enum.reduce_while(attempts(refine.max_attempts), {:error, :no_attempts, []}, fn attempt,
                                                                                    {_status,
                                                                                     _last,
                                                                                     history} ->
      inputs = maybe_add_hint(inputs, refine.feedback_fn, history)

      case DSEx.Module.call(refine.program, inputs) do
        {:ok, prediction} ->
          history = history ++ [%{attempt: attempt, prediction: prediction}]

          if safe_metric(refine.metric, prediction) |> DSEx.Metrics.pass?(),
            do: {:halt, {:ok, DSEx.Prediction.put(prediction, :refine_history, history)}},
            else: {:cont, {:ok, prediction, history}}

        {:error, reason} ->
          {:cont, {:error, reason, history}}

        other ->
          {:cont, {:error, {:invalid_refine_result, inspect(other)}, history}}
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

  defp validate_metric!(metric) when is_function(metric, 2), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Predict.Refine.new/3 expects a metric function with arity 2; got: #{inspect(metric)}"
  end

  defp validate_feedback_fn!(nil), do: :ok
  defp validate_feedback_fn!(feedback_fn) when is_function(feedback_fn, 1), do: :ok

  defp validate_feedback_fn!(feedback_fn) do
    raise ArgumentError,
          "DSEx.Predict.Refine.new/3 expects :feedback_fn to be nil or a unary function; got: #{inspect(feedback_fn)}"
  end

  defp maybe_add_hint(inputs, nil, _history), do: inputs
  defp maybe_add_hint(inputs, _feedback_fn, []), do: inputs

  defp maybe_add_hint(inputs, feedback_fn, history) do
    inputs
    |> Map.new()
    |> Map.put(:hint_, safe_feedback(feedback_fn, history))
  end

  defp safe_metric(metric, prediction) do
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

  defp safe_feedback(feedback_fn, history) do
    feedback_fn.(history)
  rescue
    error -> {:feedback_error, error_message(error)}
  catch
    kind, reason -> {:feedback_error, error_message({kind, reason})}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
