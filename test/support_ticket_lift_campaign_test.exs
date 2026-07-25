defmodule Imp.BenchmarkTruth.SupportTicketLiftCampaignTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{BudgetedLM, SupportTicketLiftCampaign}

  test "runs three paired seeds without exposing test rows to compilation" do
    factory = fn _seed, budget, _ledger ->
      inner = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)
      %BudgetedLM{inner: inner, budget: budget, max_output_tokens: 64}
    end

    artifact =
      SupportTicketLiftCampaign.run(
        runtime: :local,
        model: "static:test",
        model_metadata: %{"fixture" => true},
        lm_factory: factory
      )

    assert artifact["summary"]["execution_complete"]
    refute artifact["summary"]["c3_effectiveness_established"]
    refute artifact["summary"]["within_task_numeric_go_rule_passed"]
    assert artifact["summary"]["mean_test_lift"] == 0.0
    assert length(artifact["results"]) == 6
    assert Enum.all?(artifact["results"], &(&1["test_score"] == 0.25))
    assert Enum.all?(artifact["results"], &(length(&1["test_rows"]) == 8))

    assert artifact["budget"]["requests"] == SupportTicketLiftCampaign.expected_requests()
    assert artifact["budget"]["transport_attempts"] == 0
    assert get_in(artifact, ["dataset", "untouched_test_rows_used"]) == 8
    assert get_in(artifact, ["controls", "test_visible_to_optimizer_or_selection"]) == false

    [baseline, labeled | _] = artifact["results"]
    assert baseline["program"]["demo_count"] == 0
    assert labeled["program"]["demo_count"] == 8
    assert baseline["selection_split"] == "none"
    assert labeled["selection_split"] == "train"
  end

  test "free-provider design cannot silently expand past the 48-call preregistration" do
    assert_raise ArgumentError, ~r/pinned to eight balanced test rows/, fn ->
      SupportTicketLiftCampaign.run(
        runtime: :openrouter_free,
        api_key: "not-used",
        test_limit: 9,
        lm_factory: fn _, _, _ -> flunk("LM factory must not run") end
      )
    end
  end
end
