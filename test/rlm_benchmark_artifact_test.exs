defmodule RLMBenchmarkArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "RLM task writes honest T0 deterministic contract evidence" do
    out_dir = tmp_dir("rlm-benchmark")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rlm")

      Mix.Tasks.Imp.Benchmark.Rlm.run([
        "--data",
        "test/fixtures/benchmarks/hotpotqa-small.jsonl",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "rlm-benchmark-parity-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["all_passing"]
    assert artifact["evidence_tier"] == "t0_contract_replay"
    assert artifact["summary"]["operational_contract_replay"]
    refute artifact["summary"]["full_rlm_benchmark_parity"]
    refute artifact["summary"]["paper_protocol_complete"]
    refute Map.has_key?(artifact["summary"], "uncertainty")
    assert artifact["summary"]["approaches"]["rlm"]["accuracy"] == 1.0

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    assert rows["hp-1:rlm"]["passing"]
    assert get_in(rows, ["hp-1:rlm", "metrics", "imp_subcalls"]) == 2
    assert get_in(rows, ["hp-1:rlm", "dspy", "trace", "trajectory"]) |> length() == 1
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
