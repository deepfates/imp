defmodule Imp.Optimizer.GEPA.Evaluation do
  @moduledoc """
  Validated execution entry point for a `Imp.Optimizer.GEPA.Adapter`.

  The adapter remains responsible for execution and scoring. This module keeps
  the engine-facing contract deterministic and rejects misaligned batch data
  before it can corrupt Pareto selection or reflection.
  """

  alias Imp.Optimizer.GEPA.{Adapter, Candidate, Result}

  @doc "Evaluates and validates one candidate against an ordered example batch."
  @spec evaluate(Adapter.t(), [term()], Candidate.t(), keyword()) :: Result.t()
  def evaluate(adapter, batch, candidate, opts \\ []) when is_list(batch) and is_list(opts) do
    candidate = Candidate.validate!(candidate)
    capture_traces = Keyword.get(opts, :capture_traces, false)

    unless is_boolean(capture_traces) do
      raise ArgumentError, ":capture_traces must be a boolean"
    end

    adapter
    |> Adapter.evaluate(batch, candidate, opts)
    |> Result.validate!(length(batch), candidate, capture_traces)
  end

  @doc "Evaluates and validates ordered candidate/batch pairs through the adapter batch seam."
  @spec batch_evaluate(Adapter.t(), [{Candidate.t(), [term()]}], keyword()) :: [Result.t()]
  def batch_evaluate(adapter, items, opts \\ []) when is_list(items) and is_list(opts) do
    capture_traces = Keyword.get(opts, :capture_traces, true)

    unless is_boolean(capture_traces) do
      raise ArgumentError, ":capture_traces must be a boolean"
    end

    opts = Keyword.put(opts, :capture_traces, capture_traces)
    results = Adapter.batch_evaluate(adapter, items, opts)

    unless is_list(results) and length(results) == length(items) do
      raise ArgumentError,
            "GEPA adapter batch_evaluate/3 must return one result per item"
    end

    Enum.zip_with(items, results, fn {candidate, batch}, result ->
      Result.validate!(result, length(batch), candidate, capture_traces)
    end)
  end
end
