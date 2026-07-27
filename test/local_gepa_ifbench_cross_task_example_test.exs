defmodule LocalGEPAIFBenchCrossTaskExampleTest do
  use ExUnit.Case, async: true

  @root "examples/local_gepa_ifbench_cross_task"

  test "contract binds the pinned source-disjoint IFBench treatment" do
    contract = (@root <> "/contract.json") |> File.read!() |> Jason.decode!()
    v1 = (@root <> "/contract-v1.json") |> File.read!() |> Jason.decode!()
    manifest = (@root <> "/data/source-manifest.json") |> File.read!() |> Jason.decode!()

    assert v1["treatment_id"] == "local-gepa-ifbench-cross-task-v1"
    assert v1["status"] == "sealed"

    assert v1["authority"]["imp_predecessor_commit"] ==
             "93c454695decc8cf7a89900164d97075d42d9d6a"

    assert contract["treatment_id"] == "local-gepa-ifbench-cross-task-v2"
    assert contract["status"] == "sealed"

    assert contract["authority"]["imp_predecessor_commit"] ==
             "d588a62e4f809e3ed33c5ea7b9dd0dd560932298"

    assert contract["dataset"]["counts"] == %{
             "train" => 16,
             "selection" => 24,
             "untouched_test" => 48
           }

    assert contract["optimizer"]["seeds"] == [2_026_072_701, 2_026_072_702, 2_026_072_703]
    assert contract["optimizer"]["metric_call_limit"] == 104
    assert contract["model"]["inventory_key"] == "qwen/qwen3.6-35b-a3b"
    assert contract["model"]["selected_variant"] == "qwen/qwen3.6-35b-a3b@4bit"
    assert contract["model"]["size_bytes"] == 20_429_364_306
    assert contract["model"]["reasoning_effort"] == "none"
    assert contract["model"]["context_length"] == 262_144
    assert contract["format_canary"]["typed_output"] == %{"label" => "blue"}
    assert contract["format_canary"]["reasoning_tokens"] == 0
    assert contract["format_canary"]["transport_attempts"] == 1

    assert manifest["gepa_artifact_commit"] ==
             "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"

    split_paths = %{
      "train" => @root <> "/data/IFBench/train.jsonl",
      "dev" => @root <> "/data/IFBench/dev.jsonl",
      "test" => @root <> "/data/IFBench/test.jsonl"
    }

    assert Map.new(split_paths, fn {split, path} ->
             digest =
               path
               |> File.read!()
               |> then(&:crypto.hash(:sha256, &1))
               |> Base.encode16(case: :lower)

             {split, "sha256:" <> digest}
           end) == manifest["split_checksums"]

    ids =
      Map.new(split_paths, fn {split, path} ->
        {split,
         path
         |> File.stream!()
         |> Enum.map(&Jason.decode!(&1)["source_id"])}
      end)

    assert MapSet.disjoint?(MapSet.new(ids["train"]), MapSet.new(ids["dev"]))
    assert MapSet.disjoint?(MapSet.new(ids["train"]), MapSet.new(ids["test"]))
    assert MapSet.disjoint?(MapSet.new(ids["dev"]), MapSet.new(ids["test"]))
  end

  test "live entry is sealed, isolated, fail-closed, and spend-free" do
    runner = File.read!(@root <> "/run.exs")
    coordinator = File.read!(@root <> "/run_local.py")

    assert runner =~ "require_sealed!"
    assert runner =~ "cache: false"
    assert runner =~ "max_retries: 0"
    assert runner =~ ~s("json_fallback" => false)
    assert runner =~ "decoded_after_selected_program"
    assert runner =~ ~s("minibatch_size" => contract["optimizer"]["reflection_minibatch_size"])
    assert runner =~ ~s("usd" => 0.0)
    assert coordinator =~ ~s(if loaded:)
    assert coordinator =~ ~s("lms", "unload")
    assert coordinator =~ "require_exact_loaded_identity(identifier)"
    assert coordinator =~ "require_exact_inventory(model)"
    assert coordinator =~ ~s(/v1/models)
    assert coordinator =~ ~s("git", "status")

    assert {:ok, _quoted} = runner |> Code.string_to_quoted()
  end

  test "stopped result remains incomplete and test-opaque" do
    result = (@root <> "/exercised-result.json") |> File.read!() |> Jason.decode!()

    assert result["status"] == "stopped_incomplete"
    assert result["completed_stage"]["baseline_train"] == 0.0
    assert result["optimizer"]["candidate_count"] == 0
    assert result["optimizer"]["selection_occurred"] == false
    assert result["untouched_test"] == %{"decoded" => false, "scored" => false}
    assert result["provider_spend_usd"] == 0.0
    assert result["interpretation"] =~ "neither GEPA lift nor GEPA loss"

    v2 = (@root <> "/exercised-result-v2.json") |> File.read!() |> Jason.decode!()
    assert v2["status"] == "stopped_incomplete"
    assert v2["completed_stage"]["baseline_train"] == 0.4375
    assert v2["completed_stage"]["baseline_selection"] == 0.4375
    assert v2["optimizer"]["candidate_count"] == 0
    assert v2["untouched_test"] == %{"decoded" => false, "scored" => false}
    assert v2["interpretation"] =~ "neither a GEPA outcome nor cross-task effectiveness"
  end
end
