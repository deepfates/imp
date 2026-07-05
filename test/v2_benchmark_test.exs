defmodule V2BenchmarkTest do
  use ExUnit.Case, async: true

  @tag :v2
  test "V2 benchmark fixtures pass with deterministic scores" do
    results = DSPy.V2.Benchmarks.assert_pass!()

    assert Enum.map(results, & &1.name) == [
             :structured_extraction,
             :agent_tool_task,
             :prompt_optimization,
             :arbitrary_artifact_optimization
           ]

    assert Enum.all?(results, &(&1.score == 1.0))
  end
end
