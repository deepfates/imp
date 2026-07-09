defmodule GepaReplicationArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "GEPA replication task validates required paper-family fields and writes artifact" do
    out_dir = tmp_dir("gepa-replication")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.gepa_replication")

      Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
        "--input",
        "test/fixtures/gepa_replication/complete.json",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["full_gepa_replication"]
    assert artifact["summary"]["missing_families"] == []
    assert artifact["summary"]["missing_fields"] == []

    assert Enum.map(artifact["rows"], & &1["family"]) == [
             "AIMEBench",
             "HotpotQABench",
             "hoverBench",
             "IFBench",
             "LiveBenchMathBench",
             "Papillon"
           ]

    assert Enum.all?(artifact["rows"], fn row ->
             is_map(row["results"]["baseline"]) and
               is_map(row["results"]["dspy_gepa"]) and
               is_map(row["results"]["dsex_gepa"]) and
               is_map(row["results"]["mipro_v2"]) and
               is_map(row["token_cost"]) and
               is_map(row["seed_variance"]) and
               is_map(row["train_dev_test_gap"]) and
               is_integer(row["metric_calls"]) and
               is_integer(row["wall_clock_ms"])
           end)
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
