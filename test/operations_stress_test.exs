defmodule OperationsStressTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "operations stress artifact covers structured I/O and runtime operations" do
    artifact = Imp.BenchmarkTruth.OperationsStress.run(max_concurrency: 4)

    assert artifact["evidence_classification"] == "test_only_diagnostic"
    refute artifact["claim_eligible"]
    refute Map.has_key?(artifact, "run_context")
    assert Enum.any?(artifact["limitations"], &String.contains?(&1, "must not be admitted"))
    assert artifact["summary"]["complete"]
    assert artifact["summary"]["passing"] == 10

    by_id = Map.new(artifact["checks"], &{&1["id"], &1})

    for id <- [
          "malformed_json_rejected",
          "malformed_xml_rejected",
          "malformed_chat_missing_fields_rejected",
          "partial_stream_incremental_fields",
          "provider_native_schema_shape",
          "multimodal_content_parts_primitive_boundary",
          "save_load_round_trip_redacts_credentials",
          "cache_hit_miss_telemetry_redacted",
          "telemetry_metadata_redaction",
          "parallel_failure_isolation"
        ] do
      assert by_id[id]["passing"], "#{id} should pass"
    end

    assert by_id["cache_hit_miss_telemetry_redacted"]["evidence"]["calls"] == 1

    assert by_id["multimodal_content_parts_primitive_boundary"]["evidence"][
             "live_multimodal_reasoning_claimed"
           ] == false

    assert by_id["parallel_failure_isolation"]["evidence"]["max_concurrency"] == 4
    refute inspect(artifact) =~ "sk-test"
  end

  test "operations stress mix task writes a passing report" do
    out_dir = tmp_dir("operations-stress")

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.OperationsStress.run(["--out", out_dir, "--max-concurrency", "2"])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "operations-stress-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["evidence_classification"] == "test_only_diagnostic"
    refute artifact["claim_eligible"]
    assert artifact["summary"]["complete"]
    assert artifact["summary"]["passing"] == artifact["summary"]["total"]
  end

  test "operations stress stays outside evidence admission and public claims" do
    protocol =
      "benchmarks/reproductions.json"
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["protocols", "operations"])

    assert protocol["evidence_classification"] == "test_only_diagnostic"
    assert protocol["artifact_validator"] == nil

    operations_preflight =
      "benchmarks/research_portfolio.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("lanes")
      |> Enum.find(&(&1["id"] == "beam_operations"))
      |> Map.fetch!("preflight")

    assert operations_preflight["evidence_classification"] == "test_only_diagnostic"
    refute operations_preflight["claim_eligible"]

    catalog_commands =
      Imp.BenchmarkCatalog.families()
      |> Enum.flat_map(& &1.commands)

    refute "mix benchmark.operations_stress.check" in catalog_commands
    refute File.read!("benchmarks/claims.json") =~ "operations_stress"

    benchmark_truth = File.read!("docs/internal/BENCHMARK_TRUTH.md")

    assert benchmark_truth =~ "deliberately outside the evidence"
    assert benchmark_truth =~ "must not be admitted or cited at any C0-C5 level"
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
