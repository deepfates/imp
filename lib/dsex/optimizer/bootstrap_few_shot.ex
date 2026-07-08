defmodule DSEx.Optimizer.BootstrapFewShot do
  @moduledoc """
  Compile a predictor by selecting successful demonstrations from a trainset.

  `BootstrapFewShot` runs the current program over each training example and
  keeps examples whose predictions pass the metric. The selected examples become
  demos for the compiled program.

  Compilation also attaches a `DSEx.Optimizer.Report` so you can inspect which
  examples were selected, which were rejected, and which failed because of a
  program or metric error.
  """

  defstruct [:metric, max_bootstrapped_demos: 4]

  @option_schema [
    max_bootstrapped_demos: [type: :any, default: 4]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.BootstrapFewShot.new/2")

    %__MODULE__{
      metric: metric,
      max_bootstrapped_demos: non_negative_integer(opts[:max_bootstrapped_demos])
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    {demos, candidates, errors} =
      trainset
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {example, index}, {demos, candidates, errors} ->
        selected? = length(demos) < optimizer.max_bootstrapped_demos
        result = evaluate_example(optimizer, program, example, index, selected?)

        demos =
          if result.selected? do
            [example | demos]
          else
            demos
          end

        errors =
          case result.error do
            nil -> errors
            error -> [error | errors]
          end

        {demos, [Map.delete(result, :error) | candidates], errors}
      end)

    demos = Enum.reverse(demos)
    candidates = Enum.reverse(candidates)
    errors = Enum.reverse(errors)

    program
    |> put_demos(demos)
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
        optimizer: :bootstrap_few_shot,
        best_score: average_score(candidates),
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata: %{
          selected_count: length(demos),
          max_bootstrapped_demos: optimizer.max_bootstrapped_demos,
          trainset_size: length(candidates)
        }
      })
    )
  end

  defp evaluate_example(optimizer, program, example, index, can_select?) do
    inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()

    case safe_call(program, inputs) do
      {:ok, prediction} ->
        metric_result = safe_metric(optimizer.metric, example, prediction)
        selected? = can_select? and metric_result.passed?

        %{
          index: index,
          score: metric_result.score,
          passed?: metric_result.passed?,
          selected?: selected?,
          feedback: metric_result.feedback,
          error: metric_error(index, metric_result)
        }

      {:error, reason} ->
        %{
          index: index,
          score: 0.0,
          passed?: false,
          selected?: false,
          feedback: nil,
          error: %{index: index, stage: :program_call, reason: error_message(reason)}
        }
    end
  end

  defp safe_call(program, inputs) do
    DSEx.Module.call(program, inputs)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_metric(metric, example, prediction) do
    metric
    |> apply([example, prediction])
    |> DSEx.Metrics.normalize_result()
  rescue
    error ->
      %DSEx.Metrics.Result{
        score: 0.0,
        passed?: false,
        feedback: {:metric_error, error_message(error)},
        metadata: %{error: error}
      }
  catch
    kind, reason ->
      %DSEx.Metrics.Result{
        score: 0.0,
        passed?: false,
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{error: {kind, reason}}
      }
  end

  defp metric_error(index, %DSEx.Metrics.Result{metadata: %{error: error}}) do
    %{index: index, stage: :metric, reason: error_message(error)}
  end

  defp metric_error(_index, _result), do: nil

  defp put_demos(%DSEx.Predict.Predict{} = program, demos),
    do: DSEx.Predict.Predict.with_demos(program, demos)

  defp put_demos(%DSEx.Predict.ChainOfThought{predict: predict} = program, demos),
    do: %{program | predict: DSEx.Predict.Predict.with_demos(predict, demos)}

  defp put_demos(program, _demos), do: program

  defp average_score([]), do: 0.0

  defp average_score(candidates) do
    candidates
    |> Enum.map(& &1.score)
    |> Enum.sum()
    |> Kernel./(length(candidates))
  end

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp validate_metric!(metric) when is_function(metric, 2), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.BootstrapFewShot.new/2 expects a metric function with arity 2; got: #{inspect(metric)}"
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
