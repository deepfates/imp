defmodule SearchBenchmarkArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "source-checkout search artifact gates semantics but only measures latency" do
    artifact =
      Imp.BenchmarkTruth.Search.run(iterations: 2, max_concurrency: 2, work_ms: 1)

    assert artifact["summary"]["complete"]
    assert artifact["summary"]["passing"] == artifact["summary"]["total"]
    refute artifact["summary"]["latency_is_release_assertion"]
    refute artifact["summary"]["provider_quality_claimed"]
    refute artifact["summary"]["actual_provider_cost_available"]
    assert is_binary(artifact["source_checkout"]["git_sha"])
    assert is_boolean(artifact["source_checkout"]["dirty"])

    assert artifact["sequential"]["quality"] == 1.0
    assert artifact["bounded_concurrent"]["quality"] == 1.0

    assert get_in(artifact, ["bounded_concurrent", "cost", "projected_admitted"]) == %{
             "attempts" => 4,
             "cost_units" => 4
           }

    assert get_in(artifact, ["bounded_concurrent", "cost", "observed_executed_projection"]) ==
             %{"attempts" => 4, "cost_units" => 4}

    refute get_in(artifact, ["bounded_concurrent", "cost", "actual_provider", "available"])

    assert get_in(artifact, ["bounded_concurrent", "concurrency", "observed_peak"]) <= 2
    assert get_in(artifact, ["latency_comparison", "measurement_only"])
    refute get_in(artifact, ["latency_comparison", "speedup_required"])
  end

  test "Mix task writes the source-checkout artifact" do
    out_dir = tmp_dir("search-benchmark")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.search")

      Mix.Tasks.Imp.Benchmark.Search.run([
        "--out",
        out_dir,
        "--iterations",
        "1",
        "--max-concurrency",
        "2",
        "--work-ms",
        "0"
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "search-source-checkout-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["complete"]
    assert artifact["evidence_tier"] == "provider_free_source_checkout"
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
