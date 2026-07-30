defmodule Imp.ExperimentReferenceGraphTest do
  use ExUnit.Case, async: false

  test "five matched executions have resolvable claim links and byte-identical archives" do
    {output, status} =
      System.cmd("elixir", ["scripts/experiment_reference_graph.exs", "--check"],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output == ""
  end
end
