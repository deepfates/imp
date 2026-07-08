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
    max_bootstrapped_demos: [type: :non_neg_integer, default: 4]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(metric, 2, "DSEx.Optimizer.BootstrapFewShot.new/2", "metric")
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.BootstrapFewShot.new/2")

    %__MODULE__{
      metric: metric,
      max_bootstrapped_demos: opts[:max_bootstrapped_demos]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    {demos, candidates, errors} =
      case indexed_trainset(trainset) do
        {:ok, indexed} ->
          Enum.reduce(indexed, {[], [], []}, fn {example, index}, {demos, candidates, errors} ->
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

        {:error, error} ->
          {[], [], [%{stage: :trainset, reason: error_message(error)}]}
      end

    demos = Enum.reverse(demos)
    candidates = Enum.reverse(candidates)
    errors = Enum.reverse(errors)
    compiled = if trainset_error?(errors), do: program, else: put_demos(program, demos)

    compiled
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
          trainset_size: length(candidates),
          status: report_status(errors)
        }
      })
    )
  end

  defp indexed_trainset(trainset) do
    {:ok, Enum.with_index(trainset)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
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

  defp report_status([]), do: :ok
  defp report_status(errors) when is_list(errors), do: :with_errors

  defp trainset_error?(errors), do: Enum.any?(errors, &(&1.stage == :trainset))

  defp put_demos(program, demos) do
    case DSEx.ProgramAccess.predict(program) do
      nil -> program
      _predict -> DSEx.with_demos(program, demos)
    end
  end

  defp average_score([]), do: 0.0

  defp average_score(candidates) do
    candidates
    |> Enum.map(& &1.score)
    |> Enum.sum()
    |> Kernel./(length(candidates))
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
