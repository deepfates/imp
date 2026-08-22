defmodule Imp.OptimizerLifecycleArtifactTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.Artifact

  @root Path.expand("../examples/optimizer_lifecycles", __DIR__)
  @dataset Path.expand("../priv/tutorial/support_tickets.json", __DIR__)

  test "retained classical lifecycle is content-bound and useful after reload" do
    result = read!("exercised-classical/result.json")

    assert result["dataset"]["sha256"] == sha256(File.read!(@dataset))
    assert result["dataset"]["counts"] == %{"train" => 20, "selection" => 20, "test" => 20}
    assert result["baseline"]["test"]["score"] == 0.4

    assert result["arms"]["bootstrap_few_shot"]["test"]["score"] == 0.9
    assert result["arms"]["random_search"]["test"]["score"] == 0.95
    assert result["arms"]["knn_few_shot"]["test"]["score"] == 0.6

    assert_all_fresh!(result, 0.75)
    assert_artifacts!("exercised-classical", result)
  end

  test "retained instruction lifecycle is content-bound and useful after reload" do
    result = read!("exercised-instruction/result.json")

    assert result["git_sha"] == "a24a408660eaff7ac9b4ed2cd8691c5a177f8cf3"
    assert result["dataset"]["sha256"] == sha256(File.read!(@dataset))
    assert result["dataset"]["counts"] == %{"train" => 20, "selection" => 20, "test" => 20}
    assert result["baseline"]["test"]["score"] == 0.3

    signature = result["arms"]["signature_optimizer"]
    rules = result["arms"]["infer_rules"]
    assert signature["selection"]["score"] == 1.0
    assert signature["test"] == %{"score" => 0.95, "errors" => 0, "rows" => 20}
    assert rules["selection"]["score"] == 1.0
    assert rules["test"] == %{"score" => 0.9, "errors" => 0, "rows" => 20}
    refute signature["selected_instruction"] == source_instruction()
    refute rules["selected_instruction"] == source_instruction()

    assert get_in(result, ["budgets", "task", "active_reservations"]) == 0
    assert get_in(result, ["budgets", "optimizer", "active_reservations"]) == 0
    assert get_in(result, ["budgets", "task", "transport_attempts"]) == 288
    assert get_in(result, ["budgets", "optimizer", "transport_attempts"]) == 5

    assert_all_fresh!(result, 1.0)
    assert_artifacts!("exercised-instruction", result)
  end

  test "retained ensemble lifecycle binds its children and fresh composition" do
    result = read!("exercised-ensemble/result.json")

    assert result["git_sha"] == "e3e368f80178604d22ee3c2031f1dd295b2c7324"
    assert result["dataset"]["sha256"] == sha256(File.read!(@dataset))
    assert result["baseline"] == %{"score" => 0.3, "errors" => 0, "rows" => 20}
    assert result["ensemble"] == %{"score" => 1.0, "errors" => 0, "rows" => 20}
    assert result["fresh_process"]["score"] == %{"score" => 1.0, "errors" => 0, "rows" => 4}
    assert result["budget"]["active_reservations"] == 0
    assert result["budget"]["transport_attempts"] == 140

    Enum.each(result["artifacts"], fn {_family, artifact} ->
      path = Path.expand("../#{artifact["path"]}", __DIR__)
      assert artifact["sha256"] == sha256(File.read!(path))
      assert path |> Artifact.read!() |> Artifact.inspect() |> Map.fetch!(:champion_id)
    end)
  end

  test "retained SIMBA lifecycle binds a useful reflective mutation" do
    result = read!("exercised-simba/result.json")

    assert result["git_sha"] == "fd641406583df4072c4e415f71dfa4b1cc126eab"
    assert result["dataset"]["sha256"] == sha256(File.read!(@dataset))
    assert result["baseline"]["test"] == %{"score" => 0.35, "errors" => 0, "rows" => 20}
    assert result["selected"]["selection"] == %{"score" => 0.8, "errors" => 0, "rows" => 20}
    assert result["selected"]["test"] == %{"score" => 0.8, "errors" => 0, "rows" => 20}
    refute result["selected"]["instruction"] == source_instruction()
    assert result["report"]["candidate_count"] == 3
    assert result["report"]["errors"] == []
    assert result["fresh_process"]["score"] == %{"score" => 0.75, "errors" => 0, "rows" => 4}
    assert get_in(result, ["budgets", "task", "transport_attempts"]) == 195
    assert get_in(result, ["budgets", "reflection", "transport_attempts"]) == 3

    artifact_path = Path.join(@root, "exercised-simba/#{result["artifact"]["path"]}")
    assert result["artifact"]["sha256"] == sha256(File.read!(artifact_path))
    assert artifact_path |> Artifact.read!() |> Artifact.inspect() |> Map.fetch!(:champion_id)
  end

  defp assert_all_fresh!(result, minimum_score) do
    assert Enum.all?(result["fresh_process"], fn {_family, receipt} ->
             receipt["fresh_os_process"] and receipt["score"]["errors"] == 0 and
               receipt["score"]["score"] >= minimum_score and
               receipt["budget"]["active_reservations"] == 0
           end)
  end

  defp assert_artifacts!(directory, result) do
    Enum.each(result["artifacts"], fn {_family, artifact} ->
      path = Path.join([@root, directory, artifact["path"]])
      assert artifact["sha256"] == sha256(File.read!(path))
      assert artifact["bytes"] == File.stat!(path).size

      if String.ends_with?(path, ".parameters.json") do
        inspected = path |> Artifact.read!() |> Artifact.inspect()
        assert inspected.champion_id
        assert inspected.rollback_depth == 0
      end
    end)
  end

  defp read!(path), do: @root |> Path.join(path) |> File.read!() |> Jason.decode!()

  defp source_instruction,
    do: "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
