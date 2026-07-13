defmodule InstructionOptimizerContractArtifactTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tag timeout: 120_000
  test "pinned DSPy and DSEx pass structural MIPROv2 and SIMBA contracts without implying T3" do
    unless File.exists?("tmp/dspy-parity-venv/bin/python") and
             File.dir?("tmp/dspy-current-target/dspy") do
      flunk("run the documented current-DSPy environment setup before this source-checkout gate")
    end

    out = tmp_dir("instruction-optimizer-contract")

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.instruction_optimizer_contract")
      Mix.Tasks.Dsex.Benchmark.InstructionOptimizerContract.run(["--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "instruction-optimizer-contract-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["evidence_tier"] == "t1_instruction_optimizer_differential_contract"
    assert artifact["dspy"]["version"] == "3.3.0b1"
    assert artifact["dspy"]["commit"] == "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
    assert artifact["summary"]["structural_contract_complete"]
    assert artifact["summary"]["required_passing"] == 32
    refute artifact["summary"]["exact_sampler_sequence_parity"]
    refute artifact["summary"]["paper_protocol_complete"]
    refute artifact["summary"]["full_optimizer_parity"]
    assert Enum.all?(artifact["rows"], & &1["passing"])
    assert length(artifact["declared_native_deviations"]) == 4

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    assert rows["mipro_minibatch_schedule_12"]["status"] == "matched"
    assert rows["simba_batch_bucket_ordering"]["status"] == "matched"
    assert rows["simba_tie_strictly_between"]["actual"] == "suppress_good"
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
