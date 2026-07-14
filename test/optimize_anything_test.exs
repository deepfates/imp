defmodule OptimizeAnythingTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimize.Anything
  alias DSEx.Optimize.Anything.{Config, Result}

  test "runs the canonical Config and Result surface" do
    result =
      Anything.run("baseline", fn _candidate -> 1.0 end,
        config: Config.new(engine: [max_candidate_proposals: 0]),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component)
        end
      )

    assert %Result{} = result
    assert Result.best_candidate(result) == "baseline"
  end

  test "does not export the removed Artifact and Report compatibility functions" do
    refute function_exported?(Anything, :new_artifact, 2)
    refute function_exported?(Anything, :new_artifact, 3)
    refute function_exported?(Anything, :optimize, 2)
    refute function_exported?(Anything, :optimize, 3)
    refute function_exported?(Anything, :save_report!, 2)
    refute function_exported?(Anything, :load_report!, 1)
    refute Code.ensure_loaded?(DSEx.Optimize.Anything.Report)
    refute Code.ensure_loaded?(DSEx.Optimize.Anything.Candidate)
  end
end
