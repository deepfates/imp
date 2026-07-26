defmodule Imp.LocalSignatureOptimizerBanking77ExampleTest do
  use ExUnit.Case, async: true

  @source "examples/local_signature_optimizer_banking77/run.exs"
  @stopped_result "examples/local_signature_optimizer_banking77/exercised-stopped-result.json"

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

  test "retained malformed-proposal stop does not claim held-out evidence" do
    result = @stopped_result |> File.read!() |> Jason.decode!()

    assert result["status"] == "stopped_before_heldout"
    assert result["search"]["proposal_calls"] == 2
    assert result["search"]["distinct_admitted_proposals"] == 1
    assert result["search"]["admitted_instruction"] =~ "JSON format"
    refute result["heldout_opened"]
    refute result["fresh_process_attempted"]
    assert result["claim_boundary"] =~ "not valid proposal quality"
  end
end
