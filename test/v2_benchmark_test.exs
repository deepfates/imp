defmodule V2BenchmarkTest do
  use ExUnit.Case, async: true

  @tag :v2
  test "V2 benchmark fixtures pass with deterministic scores" do
    results = DSEx.V2.Benchmarks.assert_pass!()

    assert Enum.map(results, & &1.name) == [
             :structured_extraction,
             :agent_tool_task,
             :prompt_optimization,
             :program_reward_optimization,
             :arbitrary_artifact_optimization
           ]

    assert Enum.all?(results, &(&1.score == 1.0))
  end

  @tag :v2
  test "V2 benchmark negative controls fail below threshold" do
    results = DSEx.V2.Benchmarks.assert_negative_controls!()

    assert Enum.map(results, & &1.name) == [
             :structured_extraction_negative,
             :agent_tool_task_negative,
             :prompt_optimization_negative,
             :program_reward_optimization_negative,
             :arbitrary_artifact_optimization_negative
           ]

    assert Enum.all?(results, &(&1.score < &1.threshold))
  end
end
