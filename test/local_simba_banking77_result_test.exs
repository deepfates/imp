defmodule Imp.LocalSIMBABanking77ResultTest do
  use ExUnit.Case, async: true

  test "retained rule-only stop is negative operational evidence, not a mutation claim" do
    result =
      "examples/local_simba_banking77/exercised-rule-only-stopped-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert result["status"] == "stopped_no_admissible_mutation"
    assert result["search"]["trajectory_calls"] == 8
    assert result["search"]["candidate_count"] == 0
    assert result["search"]["reflection_transports"] == 0
    refute result["untouched_test_opened"]
    assert result["claim_boundary"] =~ "not SIMBA mutation"
  end
end
