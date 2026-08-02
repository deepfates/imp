defmodule Imp.BenchmarkTruth.GepaSuiteUpstreamConditionTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  test "pinned DSPy entrance prepares every official family without decoding heldout" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")

    common = [
      "-P",
      script,
      "--dspy-root",
      Path.join(root, "tmp/dspy-3.2.1"),
      "--gepa-root",
      Path.join(root, "tmp/gepa-v0.1.4"),
      "--artifact-root",
      Path.join(root, "tmp/gepa-artifact"),
      "--dataset-root",
      Path.join(root, "tmp/gepa-six-task-current-root"),
      "--retrieval-root",
      Path.join(root, "tmp/hover-materialization-v1/retrieval/semantic-probe-root"),
      "--retrieval-receipt",
      Path.join(root, "tmp/hover-materialization-v1/materialization.json"),
      "--arm",
      "baseline"
    ]

    for family <- Imp.BenchmarkTruth.GepaSuite.families() do
      {output, 0} = System.cmd(python, common ++ ["--family", family], stderr_to_stdout: true)
      receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert receipt["family"] == family
      assert receipt["status"] == "provider_disabled_ready"
      assert receipt["heldout_decoded"] == false
    end
  end
end
