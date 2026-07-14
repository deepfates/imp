defmodule Imp.Optimize.Anything.Progress do
  @moduledoc false

  @behaviour Imp.Optimizer.GEPA.Callback

  @enforce_keys [:io]
  defstruct [:io, :total, label: "GEPA Optimization"]

  @type t :: %__MODULE__{io: IO.device(), total: non_neg_integer() | nil, label: String.t()}

  @spec callback(keyword()) :: {module(), t()}
  def callback(opts \\ []) do
    io = Keyword.get(opts, :io, :stderr)
    total = Keyword.get(opts, :total)
    label = Keyword.get(opts, :label, "GEPA Optimization")

    unless is_nil(total) or (is_integer(total) and total >= 0) do
      raise ArgumentError, "Optimize Anything progress total must be nil or non-negative"
    end

    unless is_binary(label) and label != "" do
      raise ArgumentError, "Optimize Anything progress label must be a non-empty string"
    end

    {__MODULE__, %__MODULE__{io: io, total: total, label: label}}
  end

  @impl true
  def on_optimization_start(_event, progress), do: render(progress, 0, false)

  @impl true
  def on_budget_updated(event, progress) do
    render(progress, Map.get(event, :metric_calls_used, 0), false)
  end

  @impl true
  def on_optimization_end(event, progress) do
    calls = Map.get(event, :total_metric_calls, 0)
    render(progress, calls, true)
  end

  defp render(%__MODULE__{} = progress, calls, final?) do
    suffix = if final?, do: "\n", else: "\r"
    IO.write(progress.io, "#{progress.label}: #{count(calls, progress.total)}#{suffix}")
    :ok
  end

  defp count(calls, nil), do: "#{calls} evaluations"
  defp count(calls, total), do: "#{calls}/#{total} evaluations"
end
