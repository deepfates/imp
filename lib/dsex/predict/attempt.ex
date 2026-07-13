defmodule DSEx.Predict.Attempt do
  @moduledoc false

  @temperature 1.0

  def rollout_ids(program, count) when is_integer(count) and count > 0 do
    start = start_rollout_id(program)
    Enum.map(0..(count - 1), &(&1 + start))
  end

  def rollout_ids(_program, _count), do: []

  def bind(program, rollout_id) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
        config =
          predictor.config
          |> Keyword.put(:rollout_id, rollout_id)
          |> Keyword.put(:temperature, @temperature)

        %{predictor | config: config}
      end)
    end)
  end

  def score(metric, prediction) do
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

  def error_message(%_{} = exception), do: Exception.message(exception)
  def error_message(error), do: inspect(error)

  defp start_rollout_id(program) do
    case DSEx.ProgramParameters.predictors(program) do
      [%{predictor: predictor} | _] ->
        Keyword.get(predictor.config, :rollout_id, lm_option(predictor.lm, :rollout_id, 0))

      [] ->
        0
    end
  end

  defp lm_option(%{opts: opts}, key, default) when is_list(opts),
    do: Keyword.get(opts, key, default)

  defp lm_option(_lm, _key, default), do: default
end
