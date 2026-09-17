defmodule InstructionOptimizerContractArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  test "contract auto modes use a closed mapping independent of VM atom state" do
    contract = Mix.Tasks.Imp.Benchmark.InstructionOptimizerContract

    assert contract.auto_mode!("light") == :light
    assert contract.auto_mode!("medium") == :medium
    assert contract.auto_mode!("heavy") == :heavy

    assert_raise Mix.Error, ~r/unsupported MIPROv2 auto mode/, fn ->
      contract.auto_mode!("unexpected")
    end
  end

  defp tmp_dir(name) do
    # System.unique_integer/1 restarts at small values in every VM, so a bare
    # counter suffix collides with directories left by earlier test runs; a
    # stale artifact then satisfies the wildcard and gets asserted against.
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-#{name}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp fixture_call_projection(fixture_case) do
    Enum.map(fixture_case["input"]["calls"], fn call ->
      {call["call_id"], call["inputs"]["question"], call["outputs"]["hint"]}
    end)
  end

  defp expected_call_projection(trace_set) do
    Enum.map(0..3, fn call_index ->
      {
        "call_#{call_index}",
        "fixture-#{trace_set}-q-#{call_index}",
        "fixture-#{trace_set}-h-#{call_index}"
      }
    end)
  end
end
