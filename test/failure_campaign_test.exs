defmodule DSEx.FailureCampaignTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "records repeated normalized recovery outcomes and honest remaining live lanes" do
    artifact =
      DSEx.BenchmarkTruth.FailureCampaign.run(iterations: 3, max_concurrency: 2)

    assert artifact["summary"] == %{
             "local_cases" => 4,
             "local_passing" => 4,
             "local_complete" => true,
             "release_complete" => false,
             "remaining_live_lanes" => 2
           }

    assert artifact["runtime"]["leak_free"]
    assert Enum.all?(artifact["cases"], &(&1["flake_rate"] == 0.0))
    assert Enum.all?(artifact["cases"], &(&1["iterations"] == 3))
    assert Enum.all?(artifact["remaining"], &(&1["status"] == "blocked_on_live_probe"))
  end

  test "mix task writes the deterministic artifact" do
    out = Path.join(System.tmp_dir!(), "dsex-failure-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(out) end)

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.FailureCampaign.run([
        "--iterations",
        "2",
        "--max-concurrency",
        "2",
        "--out",
        out
      ])
    end)

    [path] = Path.wildcard(Path.join(out, "failure-campaign-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()
    assert artifact["summary"]["local_complete"]
    refute artifact["summary"]["release_complete"]
  end
end
