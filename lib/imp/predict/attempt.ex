defmodule Imp.Predict.Attempt do
  @moduledoc false

  @temperature 1.0

  def rollout_ids(program, count) when is_integer(count) and count > 0 do
    start = start_rollout_id(program)
    Enum.map(0..(count - 1), &(&1 + start))
  end

  def rollout_ids(_program, _count), do: []

  def bind(program, rollout_id) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      Imp.ProgramParameters.update_predictor(acc, name, fn predictor ->
        config =
          predictor.config
          |> Keyword.put(:rollout_id, rollout_id)
          |> Keyword.put(:temperature, @temperature)

        %{predictor | config: config}
      end)
    end)
  end

  # DSPy Refine/BestOfN score with `reward = self.reward_fn(kwargs, outputs)`
  # (dspy/predict/refine.py and dspy/predict/best_of_n.py), where `kwargs` is
  # the caller's ORIGINAL inputs — the retry hint is injected at the adapter
  # layer and never reaches the reward function. The metric therefore receives
  # an Example built from the real call inputs, never a fabricated empty one.
  def score(metric, inputs, prediction) do
    inputs = Map.new(inputs)
    example = inputs |> Imp.Example.new() |> Imp.Example.with_inputs(Map.keys(inputs))

    metric
    |> apply([example, prediction])
    |> Imp.Metrics.normalize_result()
  rescue
    error ->
      %Imp.Metrics.Result{
        feedback: {:metric_error, error_message(error)},
        metadata: %{error: error}
      }
  catch
    kind, reason ->
      %Imp.Metrics.Result{
        feedback: {:metric_error, error_message({kind, reason})},
        metadata: %{error: {kind, reason}}
      }
  end

  def error_message(%_{} = exception), do: Exception.message(exception)
  def error_message(error), do: inspect(error)

  defp start_rollout_id(program) do
    case Imp.ProgramParameters.predictors(program) do
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
