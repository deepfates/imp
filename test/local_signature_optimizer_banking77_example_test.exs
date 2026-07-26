defmodule Imp.LocalSignatureOptimizerBanking77ExampleTest do
  use ExUnit.Case, async: true

  @source "examples/local_signature_optimizer_banking77/run.exs"

  test "front door freezes disjoint train, validation, and optimizer-heldout boundaries" do
    source = File.read!(@source)

    assert source =~
             "SignatureOptimizer.compile(baseline, examples(rows.train), examples(rows.selection))"

    refute source =~ "SignatureOptimizer.compile(baseline, examples(rows.test)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Artifact.apply(program!(job, observer))"
    assert source =~ "IMP_SIGNATURE_FRESH"
  end

  test "acceptance requires natural proposals to reach rendered task messages" do
    source = File.read!(@source)

    assert source =~ "stage.proposal_status == :ok"
    assert source =~ "stage.proposal_errors == []"
    assert source =~ "Enum.all?(stage.proposals, &(&1.rendered_calls == 8))"
    assert source =~ "stage.task_calls == 24"
  end
end
