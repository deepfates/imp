defmodule DSEx.Optimizer.GEPA.Evaluation do
  @moduledoc """
  Validated execution entry point for a `DSEx.Optimizer.GEPA.Adapter`.

  The adapter remains responsible for execution and scoring. This module keeps
  the engine-facing contract deterministic and rejects misaligned batch data
  before it can corrupt Pareto selection or reflection.
  """

  alias DSEx.Optimizer.GEPA.{Adapter, Candidate, Result}

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
end
