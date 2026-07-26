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

  test "retained full-strategy run preserves mutation, validation rejection, and fresh reuse" do
    result =
      "examples/local_simba_banking77/exercised-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert result["status"] == "complete"

    assert result["split_sizes"] == %{
             "train" => 16,
             "selection" => 8,
             "untouched_test" => 40
           }

    assert result["search"]["candidate_count"] == 1
    assert result["search"]["mutated_candidates"] == 1
    assert result["search"]["rendered_mutation_calls"] == 12
    assert result["search"]["candidate_batch_score"] > result["search"]["baseline_batch_score"]

    assert result["search"]["candidate_selection_score"] <
             result["search"]["baseline_selection_score"]

    assert result["search"]["selected"] == "baseline"
    assert result["untouched_test"]["baseline"] == result["untouched_test"]["selected"]
    assert result["fresh_process"]["byte_identical"]
    assert result["fresh_process"]["logical_calls"] == 40
    assert result["claim_boundary"] =~ "not general SIMBA effectiveness"
  end
end
