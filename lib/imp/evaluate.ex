defmodule Imp.Evaluate.Result do
  @moduledoc """
  Evaluation result with aggregate score, per-example rows, and call errors.

  Rows keep the original example, prediction, normalized metric score,
  pass/fail state, feedback, metric metadata, and any program error. Optimizers
  use the same structure that you can inspect in tests and notebooks.
  """

  defstruct [:score, rows: [], errors: []]
end

defmodule Imp.EvaluationCancelledError do
  @moduledoc """
  Raised when an evaluation halts because `:max_errors` was reached.

  Mirrors DSPy's `ParallelExecutor`, which raises
  `Exception("Execution cancelled due to errors or interruption.")` once
  `error_count >= max_errors` (dspy/utils/parallelizer.py). A truncated
  evaluation must never masquerade as a completed one, so the partial rows
  and errors ride on the exception instead of a normal-looking result.
  """

  defexception [:message, :rows, :errors, :max_errors]
end

defmodule Imp.Evaluate do
  @moduledoc """
  Evaluate a program against examples and a metric.

  Evaluation is the hinge between "the model answered" and "the program got
  better." A metric turns each `(example, prediction)` pair into a score;
  optimizers use those scores to compare candidate programs.

  ## Example

      iex> lm = %{
      ...>   module: Imp.LM.Static,
      ...>   opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
      ...> }
      iex> program = Imp.predict("question -> answer", lm: lm)
      iex> devset = [
      ...>   Imp.example(question: "Capital of France?", answer: "Paris")
      ...>   |> Imp.with_inputs(:question)
      ...> ]
      iex> metric = Imp.Metrics.exact_match(:answer)
      iex> evaluator = Imp.Evaluate.new(devset, metric)
      iex> report = Imp.Evaluate.run(evaluator, program)
      iex> report.score
      1.0

  Metrics may return booleans, numbers, maps with `:score` and `:feedback`, or
  `%Imp.Metrics.Result{}`. Arity-3 metrics also receive the prediction trace.
  Program and metric failures are recorded as failed rows so optimizers can keep
  searching and report diagnostics.

  The per-row `:timeout` defaults to `:infinity`, matching DSPy's `Evaluate`
  (which imposes no per-example deadline). When a finite `:timeout` kills a row
  it is logged loudly and the row carries `{:evaluation_task_exit, :timeout}`
  with a `nil` prediction, so a killed call stays distinguishable from a wrong
  answer. A finite `:timeout` is enforced at every concurrency level,
  including the default `max_concurrency: 1`.

  When `:max_errors` is reached the evaluation halts LOUDLY by raising
  `Imp.EvaluationCancelledError`, mirroring DSPy's `ParallelExecutor`
  (halts once `error_count >= max_errors` and raises "Execution cancelled
  due to errors or interruption."). A truncated run never returns a
  normal-looking partial score. Deviation from upstream: `:max_errors`
  defaults to `:infinity` here, while DSPy inherits `dspy.settings.max_errors`
  (default 10); pass `:max_errors` explicitly for the upstream behavior.
  """

  require Logger

  defstruct [
    :devset,
    :metric,
    display_progress: false,
    failure_score: 0.0,
    max_errors: :infinity,
    max_concurrency: 1,
    timeout: :infinity,
    deadline: nil
  ]

  @option_schema [
    display_progress: [type: :boolean, default: false],
    failure_score: [type: {:or, [:integer, :float]}, default: 0.0],
    max_errors: [
      type: {:custom, __MODULE__, :validate_max_errors, []},
      default: :infinity
    ],
    max_concurrency: [type: :pos_integer, default: 1],
    timeout: [type: {:or, [:timeout, :pos_integer]}, default: :infinity],
    deadline: [type: :any, default: nil]
  ]

  def new(devset, metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Evaluate.new/3", "metric")
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Evaluate.new/3")
    devset = validate_devset!(devset)

    %__MODULE__{
      devset: devset,
      metric: metric,
      display_progress: opts[:display_progress],
      failure_score: opts[:failure_score],
      max_errors: opts[:max_errors],
      max_concurrency: opts[:max_concurrency],
      timeout: opts[:timeout],
      deadline: opts[:deadline]
    }
  end

  def validate_max_errors(:infinity), do: {:ok, :infinity}
  def validate_max_errors(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def validate_max_errors(value) do
    {:error, "expected :infinity or a non-negative integer, got: #{inspect(value)}"}
  end

  def run(%__MODULE__{} = evaluator, program) do
    case run_rows(evaluator, program) do
      {:completed, rows, errors} ->
        rows = Enum.reverse(rows)
        errors = Enum.reverse(errors)
        %Imp.Evaluate.Result{score: average(rows), rows: rows, errors: errors}

      {:cancelled, rows, errors} ->
        rows = Enum.reverse(rows)
        errors = Enum.reverse(errors)

        # DSPy parallelizer.py logs "Execution cancelled due to errors or
        # interruption." and raises; a truncated evaluation must be loud,
        # never a normal-looking partial Result with an inflated score.
        message =
          "Imp.Evaluate execution cancelled: #{length(errors)} errors reached " <>
            "max_errors #{inspect(evaluator.max_errors)} after #{length(rows)} of " <>
            "#{Enum.count(evaluator.devset)} examples"

        Logger.error(message)

        raise Imp.EvaluationCancelledError,
          message: message,
          rows: rows,
          errors: errors,
          max_errors: evaluator.max_errors
    end
  end

  # The sequential fast path only applies when no per-row timeout is
  # requested; a finite :timeout must go through the task machinery so the
  # documented kill contract holds at the default max_concurrency: 1 too.
  defp run_rows(%__MODULE__{max_concurrency: 1, timeout: :infinity} = evaluator, program) do
    evaluator.devset
    |> Enum.with_index()
    |> Enum.reduce_while({:completed, [], []}, fn {example, index}, {_tag, rows, errors} ->
      {row, error} = evaluate_with_deadline(evaluator, program, example, index)
      errors = add_error(errors, error)

      if too_many_errors?(errors, evaluator.max_errors) do
        {:halt, {:cancelled, [row | rows], errors}}
      else
        {:cont, {:completed, [row | rows], errors}}
      end
    end)
  end

  defp run_rows(%__MODULE__{} = evaluator, program) do
    evaluator
    |> evaluation_stream(program)
    |> Enum.reduce_while({:completed, [], []}, fn
      {:ok, {row, error}}, {_tag, rows, errors} ->
        errors = add_error(errors, error)

        if too_many_errors?(errors, evaluator.max_errors) do
          {:halt, {:cancelled, [row | rows], errors}}
        else
          {:cont, {:completed, [row | rows], errors}}
        end

      {:exit, reason}, {_tag, rows, errors} ->
        index = length(rows)
        error = %{index: index, reason: {:evaluation_task_exit, reason}}

        budget =
          if evaluator.deadline,
            do: "deadline: #{inspect(evaluator.deadline)}",
            else: "timeout: #{inspect(evaluator.timeout)}"

        Logger.warning(
          "Imp.Evaluate killed row #{index} (#{inspect(reason)}) after exceeding its " <>
            "time budget (#{budget}); recording failure_score " <>
            "#{inspect(evaluator.failure_score)}. This is a killed call, not a model miss - " <>
            "raise :timeout or use :infinity if your model calls are legitimately slow."
        )

        row = failed_row_data(index, nil, evaluator.failure_score, error.reason)
        errors = [error | errors]

        if too_many_errors?(errors, evaluator.max_errors) do
          {:halt, {:cancelled, [row | rows], errors}}
        else
          {:cont, {:completed, [row | rows], errors}}
        end
    end)
  end

  defp evaluation_stream(%__MODULE__{deadline: nil} = evaluator, program) do
    evaluator.devset
    |> Enum.with_index()
    |> run_evaluation_wave(evaluator, program, evaluator.timeout)
  end

  defp evaluation_stream(%__MODULE__{} = evaluator, program) do
    effective_concurrency =
      min(evaluator.max_concurrency, Imp.Settings.snapshot() |> Map.fetch!(:async_max_workers))

    evaluator.devset
    |> Enum.with_index()
    |> Enum.chunk_every(effective_concurrency)
    |> Stream.flat_map(fn wave ->
      case Imp.Optimizer.GEPA.Coordinator.remaining(evaluator.deadline) do
        0 -> Enum.map(wave, fn _item -> {:exit, :timeout} end)
        remaining -> run_evaluation_wave(wave, evaluator, program, remaining)
      end
    end)
  end

  defp run_evaluation_wave(items, evaluator, program, timeout) do
    Imp.Tasks.async_stream(
      items,
      fn {example, index} -> evaluate_with_deadline(evaluator, program, example, index) end,
      ordered: true,
      max_concurrency: evaluator.max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
  end

  defp evaluate_row(evaluator, program, example, index) do
    with {:ok, example} <- normalize_example(example),
         inputs <- example |> Imp.Example.inputs() |> Imp.Example.to_map() do
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

  defp evaluate_with_deadline(%__MODULE__{deadline: nil} = evaluator, program, example, index),
    do: evaluate_row(evaluator, program, example, index)

  defp evaluate_with_deadline(
         %__MODULE__{deadline: deadline} = evaluator,
         program,
         example,
         index
       ) do
    Imp.Optimizer.GEPA.Coordinator.with_deadline({:deadline, deadline}, fn ->
      evaluate_row(evaluator, program, example, index)
    end)
  end

  defp validate_devset!(devset) do
    if Enumerable.impl_for(devset) do
      devset
    else
      raise ArgumentError,
            "Imp.Evaluate.new/3 expects devset to be an enumerable (Enumerable) of examples, maps, or field pair lists; got: #{inspect(devset)}"
    end
  end

  defp normalize_example(%Imp.Example{} = example), do: {:ok, example}

  defp normalize_example(example) when is_map(example) or is_list(example) do
    {:ok, Imp.Example.new(example)}
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
    Imp.Module.call(program, inputs)
  end

  defp call_program(other, _inputs), do: {:error, {:not_callable, other}}

  defp metric_result(metric, example, prediction) when is_function(metric, 2),
    do: metric |> apply_metric([example, prediction]) |> Imp.Metrics.normalize_result()

  defp metric_result(metric, example, prediction) when is_function(metric, 3),
    do:
      metric
      |> apply_metric([example, prediction, trace(prediction)])
      |> Imp.Metrics.normalize_result()

  defp apply_metric(metric, args) do
    apply(metric, args)
  rescue
    error ->
      %{
        score: 0.0,
        feedback: {:metric_error, error_message(error)},
        metadata: %{imp_metric_error: error_message(error)}
      }
  catch
    kind, reason ->
      %{
        score: 0.0,
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{imp_metric_error: error_message({kind, reason})}
      }
  end

  defp trace(%Imp.Prediction{metadata: metadata}), do: Map.get(metadata, :trace)
  defp trace(_prediction), do: nil

  defp metric_error(index, %Imp.Metrics.Result{metadata: %{imp_metric_error: reason}}),
    do: %{index: index, stage: :metric, reason: reason}

  defp metric_error(_index, _result), do: nil

  defp add_error(errors, nil), do: errors
  defp add_error(errors, error), do: [error | errors]

  defp average([]), do: 0.0
  defp average(rows), do: Enum.sum(Enum.map(rows, & &1.score)) / length(rows)

  # DSPy parallelizer.py cancels once `self.error_count >= self.max_errors`
  # (checked when an error occurs, so an error-free run never cancels even at
  # max_errors: 0). The old `>` comparison was off by one against upstream.
  defp too_many_errors?([], _max_errors), do: false
  defp too_many_errors?(_errors, :infinity), do: false
  defp too_many_errors?(errors, max_errors), do: length(errors) >= max_errors

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
