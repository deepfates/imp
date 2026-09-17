defmodule Imp.MatchedGepaMiproIFBenchTest do
  use ExUnit.Case, async: false

  # Requires the pinned DSPy parity environment (scripts/setup_dspy_parity_env.sh
  # + setup_dspy_stable_source.sh) and/or example-project deps; runs in the CI
  # differential lane, not fast.check.
  @moduletag :dspy_parity

  @root Path.expand("../examples/matched_gepa_mipro_ifbench", __DIR__)

  # The v1 campaign's launch preflight: contract.exs pins the root mix.lock sha
  # of the sealed tree, so it passes only at the sealed commit. The seal cannot
  # be amended - the gepa014 successor records this contract's own sha in its
  # immutable_predecessors - and any dependency bump since moved mix.lock, so
  # at HEAD the test is unrunnable by construction.
  @tag skip:
         "v1 launch preflight pins the sealed mix.lock; permanently stopped campaign, " <>
           "unrunnable at HEAD after any dependency change (see imp-sqkr)"
  test "sealed design binds the source-disjoint two-family opportunity and maximum" do
    Code.require_file(Path.join(@root, "contract.exs"))
    plan = apply(MatchedGepaMiproIFBench.Contract, :plan!, [Path.join(@root, "contract.json")])

    assert plan["seeds"] == [2_026_072_705, 2_026_072_706, 2_026_072_707]
    assert plan["arms"] == ~w(baseline gepa mipro_v2)
    assert plan["split_counts"] == %{"train" => 16, "selection" => 32, "held_out" => 64}
    assert plan["gepa_stopping"]["semantic_max_metric_calls"] == 80
    assert plan["gepa_stopping"]["legal_iteration_metric_call_cap"] == 120
    assert plan["worst_case"]["task_calls"] == 8_928
    assert plan["worst_case"]["optimizer_calls"] == 138
    assert_in_delta plan["worst_case"]["usd"], 74.552832, 1.0e-9
  end

  test "paired coordinator preserves no-authority preflight and graceful-stop accounting" do
    {output, 0} =
      System.cmd("python3", [Path.join(@root, "paired_coordinator_test.py")],
        stderr_to_stdout: true
      )

    assert output =~ "Ran 6 tests"
    assert output =~ "OK"
  end

  test "cross-runtime guard ownership remains explicit" do
    {output, 0} =
      System.cmd("python3", [Path.join(@root, "guard_equivalence.py")], stderr_to_stdout: true)

    report = Jason.decode!(output)
    assert report["status"] == "pass"
    assert report["count"] == 14
  end

  test "stopped launch remains unscored and binds every retained artifact" do
    result = read_json!("stopped-result.json")
    assert result["status"] == "stopped_incomplete_unscored"
    refute result["held_out_loaded"]
    refute result["scored"]

    Enum.each(result["artifacts"], fn {_name, artifact} ->
      path = Path.join(@root, artifact["path"])
      assert File.regular?(path)
      assert sha256(path) == artifact["sha256"]
    end)
  end

  defp read_json!(name), do: @root |> Path.join(name) |> File.read!() |> Jason.decode!()

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
