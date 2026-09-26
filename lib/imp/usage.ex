defmodule Imp.Usage do
  @moduledoc """
  Per-prediction LM usage ledger.

  Ports DSPy 3.2.1's `track_usage` / `UsageTracker` surface
  (dspy/utils/usage_tracker.py): when the `:track_usage` setting is true,
  `Imp.Predict.call` runs inside `track/1`, every LM call that reports
  provider usage is recorded against its model, and the aggregate lands on the
  returned prediction (read it with `Imp.Prediction.get_lm_usage/1`).

  The tracker is a per-process stack. Nested trackers shadow outer ones for the
  duration of the inner call, exactly as DSPy's `settings.context(usage_tracker=...)`
  does. Parallel program runs (`Imp.Predict.Parallel`) execute in separate
  processes, so each result carries only its own usage — the isolation DSPy's
  thread-local tracker provides.
  """

  @stack_key :imp_usage_tracker_stack

  @doc """
  Runs `fun` with a fresh usage frame and returns `{result, usage}`.

  `usage` maps a model key (for example `"openai/gpt-4o-mini"`) to a merged
  usage entry, the same shape DSPy's `UsageTracker.get_total_tokens()` returns.
  """
  def track(fun) when is_function(fun, 0) do
    Process.put(@stack_key, [%{} | Process.get(@stack_key, [])])

    try do
      result = fun.()
      [frame | _rest] = Process.get(@stack_key)
      {result, frame}
    after
      case Process.get(@stack_key, []) do
        [_frame | rest] -> Process.put(@stack_key, rest)
        [] -> :ok
      end
    end
  end

  @doc "True when a usage frame is active in this process."
  def tracking?, do: Process.get(@stack_key, []) != []

  @doc """
  Records one LM call's usage from an LM result, if a frame is active.

  The model key and usage entry come from the result's provider metadata
  (`Imp.LM.Result` envelope, `:req_llm` entry). Results without usage
  metadata record nothing.
  """
  def maybe_record(result) do
    if tracking?() do
      with {:ok, metadata} <- Imp.LM.Result.metadata(result),
           %{} = provider_meta <- metadata[:req_llm] || metadata["req_llm"],
           usage when is_map(usage) and usage != %{} <-
             provider_meta[:usage] || provider_meta["usage"],
           key when is_binary(key) <- model_key(provider_meta) do
        record(key, usage)
      else
        _no_usage_metadata -> :ok
      end
    else
      :ok
    end
  end

  @doc "Adds a usage entry for `model_key` to the innermost active frame."
  def record(model_key, usage) when is_binary(model_key) and is_map(usage) do
    case Process.get(@stack_key, []) do
      [frame | rest] ->
        frame = Map.update(frame, model_key, usage, &merge_entries(&1, usage))
        Process.put(@stack_key, [frame | rest])
        :ok

      [] ->
        :ok
    end
  end

  # DSPy UsageTracker._merge_usage_entries: nested maps merge recursively,
  # numeric leaves sum, nil counts as 0.
  @doc false
  def merge_entries(entry1, entry2) when is_map(entry1) and is_map(entry2) do
    Map.merge(entry2, entry1, fn _key, value2, value1 ->
      merge_values(value1, value2)
    end)
  end

  defp merge_values(value1, value2) when is_map(value1) or is_map(value2),
    do: merge_entries(to_entry(value1), to_entry(value2))

  defp merge_values(value1, value2) when is_number(value1) or is_number(value2),
    do: (value1 || 0) + (value2 || 0)

  defp merge_values(value1, value2), do: value1 || value2

  defp to_entry(value) when is_map(value), do: value
  defp to_entry(_value), do: %{}

  defp model_key(provider_meta) do
    provider = provider_meta[:provider] || provider_meta["provider"]
    model = provider_meta[:model] || provider_meta["model"]

    cond do
      is_binary(model) and is_binary(provider) -> "#{provider}/#{model}"
      is_binary(model) -> model
      true -> nil
    end
  end
end
