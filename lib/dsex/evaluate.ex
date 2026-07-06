defmodule DSEx.Evaluate.Result do
  @moduledoc "Evaluation result with aggregate score and per-example rows."

  defstruct [:score, rows: [], errors: []]
end

defmodule DSEx.Evaluate do
  @moduledoc "Evaluate a program against examples and a metric."

  defstruct [:devset, :metric, display_progress: false, failure_score: 0.0, max_errors: :infinity]

  def new(devset, metric, opts \\ []) when is_function(metric, 2) or is_function(metric, 3) do
    %__MODULE__{
      devset: devset,
      metric: metric,
      display_progress: Keyword.get(opts, :display_progress, false),
      failure_score: Keyword.get(opts, :failure_score, 0.0),
      max_errors: Keyword.get(opts, :max_errors, :infinity)
    }
  end

  def run(%__MODULE__{} = evaluator, program) do
    {rows, errors} =
      evaluator.devset
      |> Enum.with_index()
      |> Enum.reduce_while({[], []}, fn {example, index}, {rows, errors} ->
        inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()

        {row, errors} =
          case call_program(program, inputs) do
            {:ok, prediction} ->
              result = metric_result(evaluator.metric, example, prediction)

              {%{
                 index: index,
                 example: example,
                 prediction: prediction,
                 score: result.score,
                 passed?: result.passed?,
                 feedback: result.feedback,
                 metric_metadata: result.metadata,
                 error: nil
               }, errors}

            {:error, reason} ->
              error = %{index: index, reason: reason}

              {%{
                 index: index,
                 example: example,
                 prediction: nil,
                 score: evaluator.failure_score,
                 passed?: false,
                 feedback: nil,
                 metric_metadata: %{},
                 error: reason
               }, [error | errors]}
          end

        errors = if row.error, do: errors, else: errors

        if too_many_errors?(errors, evaluator.max_errors) do
          {:halt, {[row | rows], errors}}
        else
          {:cont, {[row | rows], errors}}
        end
      end)

    rows = Enum.reverse(rows)
    errors = Enum.reverse(errors)
    %DSEx.Evaluate.Result{score: average(rows), rows: rows, errors: errors}
  end

  defp call_program(%module{} = program, inputs) do
    cond do
      function_exported?(module, :call, 2) -> module.call(program, inputs)
      true -> {:error, {:not_a_program, module}}
    end
  end

  defp metric_result(metric, example, prediction) when is_function(metric, 2),
    do: metric |> apply_metric([example, prediction]) |> DSEx.Metrics.normalize_result()

  defp metric_result(metric, example, prediction) when is_function(metric, 3),
    do:
      metric
      |> apply_metric([example, prediction, trace(prediction)])
      |> DSEx.Metrics.normalize_result()

  defp apply_metric(metric, args) do
    apply(metric, args)
  rescue
    error ->
      %{
        score: 0.0,
        feedback: {:metric_error, Exception.message(error)},
        metadata: %{error: error}
      }
  end

  defp trace(%DSEx.Prediction{metadata: metadata}), do: Map.get(metadata, :trace)
  defp trace(_prediction), do: nil

  defp average([]), do: 0.0
  defp average(rows), do: Enum.sum(Enum.map(rows, & &1.score)) / length(rows)

  defp too_many_errors?(_errors, :infinity), do: false
  defp too_many_errors?(errors, max_errors), do: length(errors) > max_errors
end
