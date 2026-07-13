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

      iex> lm = %{
      ...>   module: DSEx.LM.Static,
      ...>   opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
      ...> }
      iex> program = DSEx.predict("question -> answer", lm: lm)
      iex> devset = [
      ...>   DSEx.example(question: "Capital of France?", answer: "Paris")
      ...>   |> DSEx.with_inputs(:question)
      ...> ]
      iex> metric = DSEx.Metrics.exact_match(:answer)
      iex> evaluator = DSEx.Evaluate.new(devset, metric)
      iex> report = DSEx.Evaluate.run(evaluator, program)
      iex> report.score
      1.0

  Metrics may return booleans, numbers, maps with `:score` and `:feedback`, or
  `%DSEx.Metrics.Result{}`. Arity-3 metrics also receive the prediction trace.
  Program and metric failures are recorded as failed rows so optimizers can keep
  searching and report diagnostics.
  """

  defstruct [
    :devset,
    :metric,
    display_progress: false,
    failure_score: 0.0,
    max_errors: :infinity,
    max_concurrency: 1,
    timeout: 5000
  ]

  @option_schema [
    display_progress: [type: :boolean, default: false],
    failure_score: [type: {:or, [:integer, :float]}, default: 0.0],
    max_errors: [
      type: {:custom, __MODULE__, :validate_max_errors, []},
      default: :infinity
    ],
    max_concurrency: [type: :pos_integer, default: 1],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: 5000]
  ]

  def new(devset, metric, opts \\ []) do
    DSEx.FunctionContract.validate!(metric, [2, 3], "DSEx.Evaluate.new/3", "metric")
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Evaluate.new/3")
    devset = validate_devset!(devset)

    %__MODULE__{
      devset: devset,
      metric: metric,
      display_progress: opts[:display_progress],
      failure_score: opts[:failure_score],
      max_errors: opts[:max_errors],
      max_concurrency: opts[:max_concurrency],
      timeout: opts[:timeout]
    }
  end

  def validate_max_errors(:infinity), do: {:ok, :infinity}
  def validate_max_errors(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def validate_max_errors(value) do
    {:error, "expected :infinity or a non-negative integer, got: #{inspect(value)}"}
  end

  def run(%__MODULE__{} = evaluator, program) do
    {rows, errors} = run_rows(evaluator, program)

    rows = Enum.reverse(rows)
    errors = Enum.reverse(errors)
    %DSEx.Evaluate.Result{score: average(rows), rows: rows, errors: errors}
  end

  defp run_rows(%__MODULE__{max_concurrency: 1} = evaluator, program) do
    evaluator.devset
    |> Enum.with_index()
    |> Enum.reduce_while({[], []}, fn {example, index}, {rows, errors} ->
      {row, error} = evaluate_row(evaluator, program, example, index)
      errors = add_error(errors, error)

      if too_many_errors?(errors, evaluator.max_errors) do
        {:halt, {[row | rows], errors}}
      else
        {:cont, {[row | rows], errors}}
      end
    end)
  end

  defp run_rows(%__MODULE__{} = evaluator, program) do
    evaluator.devset
    |> Enum.with_index()
    |> DSEx.Tasks.async_stream(
      fn {example, index} -> evaluate_row(evaluator, program, example, index) end,
      ordered: true,
      max_concurrency: evaluator.max_concurrency,
      timeout: evaluator.timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({[], []}, fn
      {:ok, {row, error}}, {rows, errors} ->
        errors = add_error(errors, error)

        if too_many_errors?(errors, evaluator.max_errors) do
          {:halt, {[row | rows], errors}}
        else
          {:cont, {[row | rows], errors}}
        end

      {:exit, reason}, {rows, errors} ->
        index = length(rows)
        error = %{index: index, reason: {:evaluation_task_exit, reason}}
        row = failed_row_data(index, nil, evaluator.failure_score, error.reason)
        errors = [error | errors]

        if too_many_errors?(errors, evaluator.max_errors) do
          {:halt, {[row | rows], errors}}
        else
          {:cont, {[row | rows], errors}}
        end
    end)
  end

  defp evaluate_row(evaluator, program, example, index) do
    with {:ok, example} <- normalize_example(example),
         inputs <- example |> DSEx.Example.inputs() |> DSEx.Example.to_map() do
      case call_program(program, inputs) do
        {:ok, prediction} ->
          result = metric_result(evaluator.metric, example, prediction)
          error = metric_error(index, result)

          {%{
             index: index,
             example: example,
             prediction: prediction,
             score: result.score,
             passed?: result.passed?,
             feedback: result.feedback,
             metric_metadata: result.metadata,
             error: error
           }, error}

        {:error, reason} ->
          {failed_row_data(index, example, evaluator.failure_score, reason),
           %{
             index: index,
             reason: reason
           }}
      end
    else
      {:error, reason} ->
        {failed_row_data(index, example, evaluator.failure_score, reason),
         %{
           index: index,
           reason: reason
         }}
    end
  end

  defp validate_devset!(devset) do
    if Enumerable.impl_for(devset) do
      devset
    else
      raise ArgumentError,
            "DSEx.Evaluate.new/3 expects devset to be an enumerable (Enumerable) of examples, maps, or field pair lists; got: #{inspect(devset)}"
    end
  end

  defp normalize_example(%DSEx.Example{} = example), do: {:ok, example}

  defp normalize_example(example) when is_map(example) or is_list(example) do
    {:ok, DSEx.Example.new(example)}
  rescue
    error -> {:error, {:invalid_evaluation_example, error_message(error)}}
  end

  defp normalize_example(example), do: {:error, {:invalid_evaluation_example, inspect(example)}}

  defp failed_row_data(index, example, failure_score, reason) do
    %{
      index: index,
      example: example,
      prediction: nil,
      score: failure_score,
      passed?: false,
      feedback: nil,
      metric_metadata: %{},
      error: reason
    }
  end

  defp call_program(%_module{} = program, inputs) do
    DSEx.Module.call(program, inputs)
  end

  defp call_program(other, _inputs), do: {:error, {:not_callable, other}}

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
        metadata: %{dsex_metric_error: error_message(error)}
      }
  catch
    kind, reason ->
      %{
        score: 0.0,
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{dsex_metric_error: error_message({kind, reason})}
      }
  end

  defp trace(%DSEx.Prediction{metadata: metadata}), do: Map.get(metadata, :trace)
  defp trace(_prediction), do: nil

  defp metric_error(index, %DSEx.Metrics.Result{metadata: %{dsex_metric_error: reason}}),
    do: %{index: index, stage: :metric, reason: reason}

  defp metric_error(_index, _result), do: nil

  defp add_error(errors, nil), do: errors
  defp add_error(errors, error), do: [error | errors]

  defp average([]), do: 0.0
  defp average(rows), do: Enum.sum(Enum.map(rows, & &1.score)) / length(rows)

  defp too_many_errors?(_errors, :infinity), do: false
  defp too_many_errors?(errors, max_errors), do: length(errors) > max_errors

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
