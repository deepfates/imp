defmodule MatchedIFBenchImp.StopAccounting do
  @moduledoc """
  Normalizes a stopped run without collapsing reserved, transmitted, and
  completed calls into a single count.

  A transport telemetry event means the adapter actually attempted an HTTP
  transport. A response entry exists only after `Imp.LM.generate/3` returned.
  Consequently an interrupted request remains visible as `in_flight`; it is
  never manufactured into a completed response.
  """

  def normalize(call_budgets, responses, transports) when is_map(call_budgets) do
    budgets =
      call_budgets
      |> Enum.map(fn {{seed, arm}, budget} ->
        %{
          seed: seed,
          arm: arm,
          ceiling: budget.ceiling,
          counts: budget.counts,
          refusal_count: length(budget.refusals)
        }
      end)
      |> Enum.sort_by(&{&1.seed, &1.arm})

    reserved =
      Enum.reduce(budgets, 0, fn budget, total ->
        total + budget.counts["total_logical"]
      end)

    transmitted = length(transports)
    completed = length(responses)

    %{
      call_budgets: budgets,
      ledger: %{
        reserved: reserved,
        transmitted: transmitted,
        completed: completed,
        in_flight: transmitted - completed,
        reserved_not_transmitted: reserved - transmitted
      }
    }
  end

  def empty do
    %{
      call_budgets: [],
      ledger: %{
        reserved: 0,
        transmitted: 0,
        completed: 0,
        in_flight: 0,
        reserved_not_transmitted: 0
      }
    }
  end
end
