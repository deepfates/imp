defmodule Imp.MatchedIFBenchStopAccountingTest do
  use ExUnit.Case, async: true

  @accounting Path.expand(
                "../examples/matched_gepa_mipro_ifbench_v2/stop_accounting.exs",
                __DIR__
              )
  @v3_accounting Path.expand(
                   "../examples/matched_gepa_mipro_ifbench_v3/stop_accounting.exs",
                   __DIR__
                 )
  Code.require_file(@accounting)
  Code.require_file(@v3_accounting)

  test "a graceful stop retains an attempted call as in flight, not completed" do
    budgets = %{
      {2_026_072_705, "gepa"} => %{
        ceiling: %{
          "task_logical" => 2,
          "optimizer_logical" => 0,
          "total_logical" => 2,
          "transports" => 2
        },
        counts: %{
          "task_logical" => 2,
          "optimizer_logical" => 0,
          "total_logical" => 2,
          "transports" => 2
        },
        refusals: []
      }
    }

    accounting =
      MatchedIFBenchImp.StopAccounting.normalize(
        budgets,
        [%{result: {:ok, :first}}],
        [%{count: 1}, %{count: 1}]
      )

    assert accounting.ledger == %{
             reserved: 2,
             transmitted: 2,
             completed: 1,
             in_flight: 1,
             reserved_not_transmitted: 0
           }

    assert accounting.call_budgets == [
             %{
               seed: 2_026_072_705,
               arm: "gepa",
               ceiling: budgets[{2_026_072_705, "gepa"}].ceiling,
               counts: budgets[{2_026_072_705, "gepa"}].counts,
               refusal_count: 0
             }
           ]
  end

  test "a reservation interrupted before transport remains separately visible" do
    budgets = %{
      {1, "baseline"} => %{
        ceiling: %{"total_logical" => 1},
        counts: %{"total_logical" => 1},
        refusals: []
      }
    }

    assert MatchedIFBenchImp.StopAccounting.normalize(budgets, [], []).ledger == %{
             reserved: 1,
             transmitted: 0,
             completed: 0,
             in_flight: 0,
             reserved_not_transmitted: 1
           }
  end

  test "v3 stop accounting never manufactures an interrupted response" do
    budgets = %{
      {2_026_072_705, "gepa"} => %{
        ceiling: %{"total_logical" => 2},
        counts: %{"total_logical" => 2},
        refusals: []
      }
    }

    assert MatchedIFBenchV3Imp.StopAccounting.normalize(
             budgets,
             [%{result: {:ok, :first}}],
             [%{count: 1}, %{count: 1}]
           ).ledger == %{
             reserved: 2,
             transmitted: 2,
             completed: 1,
             failed: 0,
             in_flight: 1,
             reserved_not_transmitted: 0
           }
  end
end
