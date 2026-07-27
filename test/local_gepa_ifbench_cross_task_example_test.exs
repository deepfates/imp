defmodule LocalGEPAIFBenchCrossTaskExampleTest do
  use ExUnit.Case, async: true

  @root "examples/local_gepa_ifbench_cross_task"

  test "contract binds the pinned source-disjoint IFBench treatment" do
    contract = (@root <> "/contract.json") |> File.read!() |> Jason.decode!()
    manifest = (@root <> "/data/source-manifest.json") |> File.read!() |> Jason.decode!()

    assert contract["treatment_id"] == "local-gepa-ifbench-cross-task-v1"
    assert contract["status"] == "sealed"

    assert contract["authority"]["imp_predecessor_commit"] ==
             "93c454695decc8cf7a89900164d97075d42d9d6a"

    assert contract["dataset"]["counts"] == %{
             "train" => 16,
             "selection" => 24,
             "untouched_test" => 48
           }

    assert contract["optimizer"]["seeds"] == [2_026_072_701, 2_026_072_702, 2_026_072_703]
    assert contract["optimizer"]["metric_call_limit"] == 104

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
    assert coordinator =~ ~s(/v1/models)
    assert coordinator =~ ~s("git", "status")

    assert {:ok, _quoted} = runner |> Code.string_to_quoted()
  end
end
