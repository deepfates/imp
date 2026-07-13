defmodule DSEx.Optimizer.Trajectory do
  @moduledoc false

  @enforce_keys [:index, :example, :score]
  defstruct [
    :index,
    :example,
    :prediction,
    :trace,
    :score,
    :feedback,
    :metric_metadata,
    :error,
    :program_id,
    :rollout_id
  ]
end

defmodule DSEx.Optimizer.TrajectoryRunner do
  @moduledoc false

  alias DSEx.Optimizer.{Trace, Trajectory}

  @spec run(struct(), Enumerable.t(), function(), keyword()) :: [Trajectory.t()]
  def run(program, examples, metric, opts \\ []) do
    program = annotate_predictors(program)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    timeout = Keyword.get(opts, :timeout, 5_000)

    examples
    |> Enum.to_list()
    |> Enum.with_index()
    |> DSEx.Tasks.async_stream(
      fn {example, index} -> evaluate(program, example, index, metric, opts) end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, trajectory} ->
        trajectory

      {:exit, {{example, index}, reason}} ->
        failed(index, normalize_example(example), [], {:task_exit, reason}, opts)

      {:exit, reason} ->
        failed(-1, nil, [], {:task_exit, reason}, opts)
    end)
  end

  defp evaluate(program, example, index, metric, opts) do
    example = normalize_example(example)
    inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()
    Trace.start()

    case safe_call(program, inputs) do
      {:ok, %DSEx.Prediction{} = prediction} ->
        trace =
          case Trace.finish() do
            [] ->
              prediction.metadata[:optimizer_trace] || prediction.metadata["optimizer_trace"] ||
                []

            captured ->
              captured
          end

        result = safe_metric(metric, example, prediction, trace)

        %Trajectory{
          index: index,
          example: example,
          prediction: prediction,
          trace: trace,
          score: result.score,
          feedback: result.feedback,
          metric_metadata: result.metadata,
          error: metric_error(result),
          program_id: Keyword.get(opts, :program_id),
          rollout_id: Keyword.get(opts, :rollout_id)
        }

      {:error, reason} ->
        trace = Trace.finish()
        result = safe_metric(metric, example, nil, trace)

        %Trajectory{
          index: index,
          example: example,
          prediction: nil,
          trace: trace,
          score: result.score,
          feedback: result.feedback,
          metric_metadata: result.metadata,
          error: reason,
          program_id: Keyword.get(opts, :program_id),
          rollout_id: Keyword.get(opts, :rollout_id)
        }
    end
  rescue
    error ->
      failed(index, normalize_example(example), Trace.finish(), Exception.message(error), opts)
  catch
    kind, reason ->
      failed(index, normalize_example(example), Trace.finish(), {kind, reason}, opts)
  end

  defp annotate_predictors(program) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, program ->
      DSEx.ProgramParameters.update_predictor(program, name, fn predictor ->
        %{predictor | metadata: Map.put(predictor.metadata, :optimizer_predictor_name, name)}
      end)
    end)
  end

  defp safe_call(program, inputs) do
    case DSEx.Module.call(program, inputs) do
      {:ok, %DSEx.Prediction{}} = success -> success
      {:ok, other} -> {:error, {:invalid_prediction, other}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_program_result, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_metric(metric, example, prediction, trace) do
    args =
      if is_function(metric, 3), do: [example, prediction, trace], else: [example, prediction]

    metric |> apply(args) |> DSEx.Metrics.normalize_result()
  rescue
    error ->
      DSEx.Metrics.normalize_result(%{
        score: 0.0,
        feedback: {:metric_error, Exception.message(error)},
        metadata: %{dsex_metric_error: Exception.message(error)}
      })
  catch
    kind, reason ->
      DSEx.Metrics.normalize_result(%{
        score: 0.0,
        feedback: {:metric_error, {kind, reason}},
        metadata: %{dsex_metric_error: {kind, reason}}
      })
  end

  defp metric_error(%DSEx.Metrics.Result{metadata: %{dsex_metric_error: reason}}),
    do: {:metric_error, reason}

  defp metric_error(_result), do: nil

  defp failed(index, example, trace, reason, opts) do
    %Trajectory{
      index: index,
      example: example,
      prediction: nil,
      trace: trace,
      score: 0.0,
      feedback: nil,
      metric_metadata: %{},
      error: reason,
      program_id: Keyword.get(opts, :program_id),
      rollout_id: Keyword.get(opts, :rollout_id)
    }
  end

  defp normalize_example(%DSEx.Example{} = example), do: example
  defp normalize_example(example), do: DSEx.Example.new(example)
end
