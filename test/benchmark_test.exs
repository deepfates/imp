defmodule BenchmarkTest do
  use ExUnit.Case, async: true

  test "benchmark fixtures pass with deterministic scores" do
    results = Imp.Benchmarks.assert_pass!()

    assert Enum.map(results, & &1.name) == [
             :structured_extraction,
             :supervised_tool_policy_task,
             :prompt_optimization,
             :program_reward_optimization,
             :arbitrary_artifact_optimization
           ]

    assert Enum.all?(results, &(&1.score == 1.0))
  end

  test "benchmark negative controls fail below threshold" do
    results = Imp.Benchmarks.assert_negative_controls!()

    assert Enum.map(results, & &1.name) == [
             :structured_extraction_negative,
             :supervised_tool_policy_task_negative,
             :prompt_optimization_negative,
             :program_reward_optimization_negative,
             :arbitrary_artifact_optimization_negative
           ]

    assert Enum.all?(results, &(&1.score < &1.threshold))
  end
end
