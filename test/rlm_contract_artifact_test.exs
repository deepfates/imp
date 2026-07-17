defmodule RLMContractArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  @tag timeout: 120_000
  test "current DSPy and Imp pass the T1 operational contract without implying T3" do
    unless File.exists?("tmp/dspy-parity-venv/bin/python") and
             File.dir?("tmp/dspy-current-target/dspy") do
      flunk("run the documented current-DSPy environment setup before this source-checkout gate")
    end

    out = tmp_dir("rlm-contract")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rlm_contract")

      Mix.Tasks.Imp.Benchmark.RlmContract.run([
        "--cases",
        "test/fixtures/rlm_contract_cases.json",
        "--out",
        out
      ])
    end)

    [path] = Path.wildcard(Path.join(out, "rlm-operational-contract-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["evidence_tier"] == "t1_operational_contract"
    assert artifact["dspy"]["dspy_version"] == "3.3.0b1"
    assert artifact["dspy"]["deno_version"] == "2.8.3"
    assert artifact["summary"]["operational_contract_complete"]
    refute artifact["summary"]["paper_protocol_complete"]
    assert artifact["summary"]["required_matched_passing"] == 12

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    assert Enum.all?(artifact["rows"], & &1["passing"])
    assert get_in(rows, ["reject_over_budget_batch", "imp", "subcalls"]) == 0

    assert rows["imp_symbolic_recurse_extension"]["disposition"] == "deviation"
    refute rows["imp_symbolic_recurse_extension"]["imp"]["executed"]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
