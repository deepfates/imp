defmodule RLMBenchmarkArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "RLM benchmark task writes a passing DSEx-vs-DSPy artifact" do
    out_dir = tmp_dir("rlm-benchmark")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.rlm")

      Mix.Tasks.Dsex.Benchmark.Rlm.run([
        "--data",
        "test/fixtures/benchmarks/hotpotqa-small.jsonl",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rlm-benchmark-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["summary"]["full_rlm_benchmark_parity"]
    assert artifact["summary"]["approaches"]["rlm"]["accuracy"] == 1.0

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    assert rows["hp-1:rlm"]["passing"]
    assert get_in(rows, ["hp-1:rlm", "metrics", "dsex_subcalls"]) == 2
    assert get_in(rows, ["hp-1:rlm", "dspy", "trace", "trajectory"]) |> length() == 1
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
