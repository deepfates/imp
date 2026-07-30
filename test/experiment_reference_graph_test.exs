defmodule Imp.ExperimentReferenceGraphTest do
  use ExUnit.Case, async: false

  test "five matched executions have resolvable claim links and byte-identical archives" do
    {output, status} =
      System.cmd("elixir", ["scripts/experiment_reference_graph.exs", "--check"],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output == ""
  end

  test "path-aware graph resolves relative and constructed dependencies without prefix collisions" do
    {output, 0} =
      System.cmd("elixir", ["scripts/experiment_reference_graph.exs"],
        cd: File.cwd!(),
        stderr_to_stdout: true
      )

    edges = output |> :json.decode() |> Map.fetch!("dependency_edges")

    assert edge?(
             edges,
             "scripts/dspy_optimizer_public_workflow_gate.py",
             "examples/matched_gepa_mipro_ifbench"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_v2/contract.json",
             "examples/matched_gepa_mipro_ifbench"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_v3/contract.json",
             "examples/matched_gepa_mipro_ifbench_v2"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_gepa014/contract.json",
             "examples/matched_gepa_mipro_ifbench_v3"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_gepa014/run_upstream.py",
             "examples/matched_gepa_mipro_ifbench"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_gepa014/run_paired.py",
             "examples/matched_gepa_mipro_ifbench_v2"
           )

    assert edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_gepa014/run_paired.py",
             "examples/matched_gepa_mipro_ifbench_v3"
           )

    refute edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_v2/mix.exs",
             "examples/matched_gepa_mipro_ifbench"
           )

    refute edge?(
             edges,
             "examples/matched_gepa_mipro_ifbench_v3/mix.exs",
             "examples/matched_gepa_mipro_ifbench"
           )
  end

  defp edge?(edges, source, target) do
    Enum.any?(edges, &(&1["source"] == source and &1["target"] == target))
  end
end
