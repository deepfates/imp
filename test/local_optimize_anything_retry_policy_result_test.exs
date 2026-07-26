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
end
