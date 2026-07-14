defmodule Imp.BenchmarkTruth.AutoEvaluationContractTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.{AutoEvaluationContract, RunContext}

  test "canonical manifest executes all pinned provider-free semantics" do
    manifest = AutoEvaluationContract.load_manifest!()
    assert Enum.map(manifest["cases"], & &1["id"]) == ~w(
      semantic_direct_harmonic_mean
      semantic_trace_threshold
      semantic_decompositional_contract
      semantic_clamped_helper
      complete_grounded_independent_trace
      complete_grounded_zero_direct
    )
    assert byte_size(manifest["sha256"]) == 64
  end

  test "artifact validator admits an exact execution and rejects semantic tampering" do
    artifact = valid_artifact()
    assert AutoEvaluationContract.validate_artifact!(artifact) == artifact

    forged = put_in(artifact, ["rows", Access.at(0), "actual", "f1"], 1.0)
    forged = reseal(forged)

    assert_raise ArgumentError, ~r/invalid auto-evaluation differential artifact/, fn ->
      AutoEvaluationContract.validate_artifact!(forged)
    end
  end

  test "manifest rejects authority drift" do
    manifest = AutoEvaluationContract.load_manifest!() |> Map.delete("sha256")
    forged = put_in(manifest, ["authority", "commit"], String.duplicate("0", 40))

    assert_raise ArgumentError, ~r/manifest contract does not match v1/, fn ->
      AutoEvaluationContract.validate_manifest!(forged)
    end
  end

  test "manifest rejects unknown top-level keys" do
    manifest = AutoEvaluationContract.load_manifest!() |> Map.delete("sha256")

    assert_raise ArgumentError, ~r/manifest contract does not match v1/, fn ->
      AutoEvaluationContract.validate_manifest!(Map.put(manifest, "notes", "mutable"))
    end
  end

  test "manifest rejects a coordinated judgment and expected-score rewrite" do
    manifest = AutoEvaluationContract.load_manifest!() |> Map.delete("sha256")

    forged =
      manifest
      |> put_in(["cases", Access.at(0), "judgments", "precision"], 0.2)
      |> put_in(["cases", Access.at(0), "expected", "f1"], 0.9)
      |> put_in(["cases", Access.at(0), "expected", "score"], 0.9)

    assert_raise ArgumentError, ~r/manifest contract does not match v1/, fn ->
      AutoEvaluationContract.validate_manifest!(forged)
    end
  end

  defp valid_artifact do
    output = Path.join(System.tmp_dir!(), "auto-eval-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(output) end)

    AutoEvaluationContract.run!(output: output, allow_dirty: true).artifact
  end

  defp reseal(artifact) do
    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])

    context =
      RunContext.new!(
        source_commits: %{
          "imp" => "deepfates/imp@fixture",
          "dspy" => "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"
        }
      )

    RunContext.finish(context, payload)
  end
end
