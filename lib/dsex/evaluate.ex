defmodule DSEx.Evaluate.Result do
  @moduledoc """
  Evaluation result with aggregate score, per-example rows, and call errors.

  Rows keep the original example, prediction, normalized metric score,
  pass/fail state, feedback, metric metadata, and any program error. Optimizers
  use the same structure that you can inspect in tests and notebooks.
  """

  defstruct [:score, rows: [], errors: []]
end

defmodule DSEx.Evaluate do
  @moduledoc """
  Evaluate a program against examples and a metric.

  Evaluation is the hinge between "the model answered" and "the program got
  better." A metric turns each `(example, prediction)` pair into a score;
  optimizers use those scores to compare candidate programs.

  ## Example

      devset = [
        DSEx.example(question: "Capital of France?", answer: "Paris")
        |> DSEx.with_inputs(:question)
      ]

      metric = DSEx.Metrics.exact_match(:answer)

      evaluator = DSEx.Evaluate.new(devset, metric)
      report = DSEx.Evaluate.run(evaluator, program)

      report.score

  Metrics may return booleans, numbers, maps with `:score` and `:feedback`, or
  `%DSEx.Metrics.Result{}`. Arity-3 metrics also receive the prediction trace.
  Program and metric failures are recorded as failed rows so optimizers can keep
  searching and report diagnostics.
  """

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
    result =
      cond do
        function_exported?(module, :call, 2) -> module.call(program, inputs)
        true -> {:error, {:not_a_program, module}}
      end

    case result do
      {:ok, %DSEx.Prediction{} = prediction} -> {:ok, prediction}
      {:ok, other} -> {:error, {:invalid_program_prediction, inspect(other)}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program_result, inspect(other)}}
    end
  rescue
    error -> {:error, {:program_error, error_message(error)}}
  catch
    kind, reason -> {:error, {:program_error, error_message({kind, reason})}}
  end

  defp call_program(other, _inputs), do: {:error, {:not_a_program, other}}

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
        feedback: {:metric_error, error_message(error)},
        metadata: %{error: error}
      }
  catch
    kind, reason ->
      %{
        score: 0.0,
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{error: {kind, reason}}
      }
  end

  defp trace(%DSEx.Prediction{metadata: metadata}), do: Map.get(metadata, :trace)
  defp trace(_prediction), do: nil

  defp average([]), do: 0.0
  defp average(rows), do: Enum.sum(Enum.map(rows, & &1.score)) / length(rows)

  defp too_many_errors?(_errors, :infinity), do: false
  defp too_many_errors?(errors, max_errors), do: length(errors) > max_errors

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
