defmodule Imp.Optimizer.MIPROv2GroundingDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure
  @python "tmp/dspy-current-venv/bin/python"
  @target "tmp/dspy-current-target"
  @runner "test/support/dspy_mipro_grounding_tape.py"

  test "multi-predictor decision tape matches exact DSPy 3.3.1 grounding" do
    unless File.exists?(@python) and File.dir?(Path.join(@target, "dspy")) do
      flunk("run scripts/setup_dspy_current_target.sh and scripts/setup_reference_test_env.sh")
    end

    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)],
        env: [{"PYTHONPATH", Path.expand(@target)}],
        stderr_to_stdout: true
      )

    upstream = Jason.decode!(output)
    assert upstream["dspy_version"] == "3.3.1"

    assert upstream["grounded_proposer_sha256"] ==
             "c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3"

    assert upstream["instruction_counts"] == %{"0" => 4, "1" => 4}

    expected_demo_ids = [
      [],
      ["A1", "A2", "B1"],
      ["A1", "A2", "B1"],
      ["B1", "B2", "A1"]
    ]

    assert Enum.map(upstream["calls"], & &1["rollout_id"]) == Enum.to_list(100..107)

    upstream["calls"]
    |> Enum.chunk_every(4)
    |> Enum.with_index()
    |> Enum.each(fn {calls, predictor_index} ->
      assert Enum.map(calls, & &1["predictor_index"]) ==
               List.duplicate(predictor_index, 4)

      assert Enum.map(calls, & &1["proposal_index"]) == [0, 1, 2, 3]

      actual_ids =
        Enum.map(calls, fn call ->
          Regex.scan(~r/P#{predictor_index}-([AB]\d)/, call["task_demos"],
            capture: :all_but_first
          )
          |> List.flatten()
          |> Enum.uniq()
        end)

      assert actual_ids == expected_demo_ids
      refute Enum.any?(calls, &String.contains?(&1["task_demos"], "-L"))
    end)
  end
end
