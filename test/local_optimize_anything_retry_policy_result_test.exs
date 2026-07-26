defmodule Imp.LocalOptimizeAnythingRetryPolicyResultTest do
  use ExUnit.Case, async: true

  test "retained strict-decoder stop does not masquerade as optimization" do
    result =
      "examples/local_optimize_anything_retry_policy/exercised-stopped-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert result["status"] == "stopped_invalid_structured_proposal"
    assert result["failure"]["expected_type"] == "integer"
    assert result["failure"]["returned_shape"] == "object"
    refute result["candidate_evaluated"]
    refute result["selection_opened"]
    refute result["untouched_test_opened"]
    assert result["claim_boundary"] =~ "not Optimize Anything mutation"
  end

  test "retained recorder stop does not infer its lost in-memory winner" do
    result =
      "examples/local_optimize_anything_retry_policy/exercised-recorder-stopped-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert result["status"] == "stopped_after_optimization_before_durable_result"
    assert result["optimizer_returned"]
    refute result["durable_selection_result"]
    refute result["untouched_test_opened"]
    assert result["claim_boundary"] =~ "winner"
  end

  test "completed local condition preserves strict rejection and fresh baseline use" do
    result =
      "examples/local_optimize_anything_retry_policy/exercised-result.json"
      |> File.read!()
      |> Jason.decode!()

    assert result["status"] == "complete_with_rejected_proposal"
    assert result["proposal_calls"] == 4
    assert result["candidate_count"] == 1
    assert result["selected"] == "baseline"
    assert result["untouched_test"]["baseline"] == result["untouched_test"]["selected"]
    assert result["fresh_process"]["byte_identical"]
    assert result["claim_boundary"] =~ "no admitted mutation"
  end
end
