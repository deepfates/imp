defmodule Imp.BenchmarkTruth.OverheadPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.OverheadPolicy

  test "every named operation has absolute and reference-relative budgets with rationale" do
    budgets = OverheadPolicy.budgets()

    assert Map.keys(budgets) |> Enum.sort() ==
             ~w(
               adapter_format
               adapter_parse
               cache_hit
               cache_miss
               concurrent_orchestration
               evaluation_loop
               metric_normalization
               optimizer_trial_scheduling
               schema_validate
               signature_parse
               trace_redaction_serialization
             )

    assert Enum.all?(budgets, fn {_id, budget} ->
             budget["max_imp_median_us"] > 0 and
               budget["max_median_ratio_to_reference"] > 0 and
               budget["policy"] == "regression_guard_not_speed_claim" and
               is_binary(budget["rationale"]) and budget["rationale"] != ""
           end)
  end

  test "evaluation requires both budgets and labels ratios as measurements" do
    passing =
      OverheadPolicy.evaluate!(
        "cache_hit",
        %{"median_us" => 1.0},
        %{"median_us" => 0.1}
      )

    assert passing["passing"]

    assert passing["checks"] == %{
             "absolute_median" => true,
             "reference_relative_median" => true
           }

    assert passing["measurements"]["median_ratio_imp_over_dspy"] == 10.0
    refute passing["measurements"]["ratio_is_speed_claim"]
    assert passing["budget"]["operation_contract"] =~ "timed lookup"

    refute OverheadPolicy.evaluate!(
             "cache_hit",
             %{"median_us" => 25.0},
             %{"median_us" => 10.0}
           )["passing"]
  end

  test "complete authority rejects missing cases and claimed ratios" do
    cases =
      Enum.map(OverheadPolicy.budgets(), fn {id, _budget} ->
        OverheadPolicy.evaluate!(id, %{"median_us" => 0.01}, %{"median_us" => 1.0})
      end)

    assert OverheadPolicy.complete?(cases)
    refute OverheadPolicy.complete?(tl(cases))
    refute OverheadPolicy.complete?([hd(cases) | cases])

    [first | rest] = cases
    forged = put_in(first, ["measurements", "ratio_is_speed_claim"], true)
    refute OverheadPolicy.complete?([forged | rest])
  end
end
