defmodule OptimizerLiftArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "optimizer lift artifact includes passing natural user-story lanes" do
    out_dir = tmp_dir("optimizer-lift")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.optimizer_lift")
      Mix.Tasks.Imp.Benchmark.OptimizerLift.run(["--out", out_dir])
    end)

    [artifact_path] = Path.wildcard(Path.join(out_dir, "optimizer-lift-parity-*.json"))
    artifact = artifact_path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["natural_lanes"]["all_passing"]
    assert artifact["summary"]["natural_lanes"]["total"] == 4

    lanes = Map.new(artifact["natural_lanes"], &{&1["id"], &1})

    assert Map.keys(lanes) |> Enum.sort() == [
             "classification_colors",
             "instruction_following_exact",
             "qa_paraphrase",
             "retrieval_knn_few_shot"
           ]

    for {_id, lane} <- lanes do
      assert lane["passing"]
      assert lane["baseline_score"] == 0.0
      assert lane["optimized_score"] == 1.0
      assert lane["lift"] == 1.0
      assert lane["lm_calls"] > 0
      assert lane["estimated_cost"]["provider"] == "fixture"
      assert lane["comparison_status"] == "imp_release_evidence"
    end

    assert length(lanes["classification_colors"]["selected"]["demos"]) == 2
    assert length(lanes["qa_paraphrase"]["selected"]["demos"]) == 1
    assert length(lanes["retrieval_knn_few_shot"]["selected"]["demos"]) == 1
    assert lanes["instruction_following_exact"]["selected"]["instructions"] != []
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
