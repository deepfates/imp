defmodule Imp.BenchmarkTruth.EvidenceAdmissionTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.EvidenceAdmission
  alias Imp.ReproductionRegistry

  @artifact "benchmarks/evidence/admitted/auto_evaluation_contract/9f7210133747e00ea2f0a187a90babb3ba8d41d558a410735f8185e8013b63c0.json"

  test "admission is idempotent, validated, and updates an ordered registry atomically" do
    registry_path = temporary_registry!()

    result =
      EvidenceAdmission.admit!(
        artifact_path: @artifact,
        protocol_id: "auto_evaluation_contract",
        tier: "t1",
        feature_ids: ["semantic_f1", "complete_and_grounded"],
        registry_path: registry_path
      )

    assert result.artifact == @artifact
    assert result.artifact_sha256 == Path.basename(@artifact, ".json")
    assert File.read!(result.artifact) == File.read!(@artifact)

    updated = registry_path |> File.read!() |> Jason.decode!()

    for feature_id <- result.features do
      feature = Enum.find(updated["features"], &(&1["id"] == feature_id))
      assert feature["admitted_evidence"]["artifact"] == @artifact
      assert feature["admitted_evidence"]["protocol_id"] == "auto_evaluation_contract"
      assert feature["admitted_evidence"]["tier"] == "t1"
    end
  end

  test "a declared validator can perform the protocol's first admission" do
    registry_path = temporary_registry!()

    registry =
      registry_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("features", fn features ->
        Enum.map(features, fn feature ->
          if feature["id"] in ["semantic_f1", "complete_and_grounded"] do
            Map.put(feature, "admitted_evidence", %{
              "tier" => "none",
              "artifact" => nil,
              "artifact_sha256" => nil,
              "protocol_id" => nil
            })
          else
            feature
          end
        end)
      end)

    File.write!(registry_path, Jason.encode!(registry, pretty: true) <> "\n")

    result =
      EvidenceAdmission.admit!(
        artifact_path: @artifact,
        protocol_id: "auto_evaluation_contract",
        tier: "t1",
        feature_ids: ["semantic_f1", "complete_and_grounded"],
        registry_path: registry_path
      )

    assert result.artifact == @artifact

    updated = registry_path |> File.read!() |> Jason.decode!()

    assert Enum.all?(updated["features"], fn feature ->
             feature["id"] not in result.features or
               get_in(feature, ["admitted_evidence", "protocol_id"]) ==
                 "auto_evaluation_contract"
           end)
  end

  test "a valid source-bound refresh can replace an invalid prior artifact" do
    registry_path = temporary_registry!()

    registry =
      registry_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.update!("features", fn features ->
        Enum.map(features, fn feature ->
          if feature["id"] in ["semantic_f1", "complete_and_grounded"] do
            put_in(feature["admitted_evidence"], %{
              "tier" => "t1",
              "artifact" =>
                "benchmarks/evidence/admitted/auto_evaluation_contract/#{String.duplicate("0", 64)}.json",
              "artifact_sha256" => String.duplicate("0", 64),
              "protocol_id" => "auto_evaluation_contract"
            })
          else
            feature
          end
        end)
      end)

    File.write!(registry_path, Jason.encode!(registry, pretty: true) <> "\n")

    result =
      EvidenceAdmission.admit!(
        artifact_path: @artifact,
        protocol_id: "auto_evaluation_contract",
        tier: "t1",
        feature_ids: ["semantic_f1", "complete_and_grounded"],
        registry_path: registry_path
      )

    assert result.artifact == @artifact
    assert result.features == ["semantic_f1", "complete_and_grounded"]
  end

  test "admission rejects an undeclared feature/protocol pair before writing" do
    registry_path = temporary_registry!()

    assert_raise ArgumentError, ~r/does not declare protocol/, fn ->
      EvidenceAdmission.admit!(
        artifact_path: @artifact,
        protocol_id: "auto_evaluation_contract",
        tier: "t1",
        feature_ids: ["product_release"],
        registry_path: registry_path
      )
    end
  end

  test "content-addressed paths reject unsafe protocol ids and malformed digests" do
    assert ReproductionRegistry.admitted_path(
             "auto_evaluation_contract",
             String.duplicate("a", 64)
           ) ==
             "benchmarks/evidence/admitted/auto_evaluation_contract/#{String.duplicate("a", 64)}.json"

    assert_raise ArgumentError, fn ->
      ReproductionRegistry.admitted_path("../escape", String.duplicate("a", 64))
    end

    assert_raise ArgumentError, fn ->
      ReproductionRegistry.admitted_path("valid", "short")
    end
  end

  defp temporary_registry! do
    root = Path.join(System.tmp_dir!(), "imp-admission-#{System.unique_integer([:positive])}")
    path = Path.join(root, "reproductions.json")
    File.mkdir_p!(root)
    File.cp!("benchmarks/reproductions.json", path)
    on_exit(fn -> File.rm_rf!(root) end)
    path
  end
end
