defmodule Imp.LocalMIPROBanking77ExampleTest do
  use ExUnit.Case, async: true

  @result "examples/local_mipro_banking77/exercised-result.json"
  @source "examples/local_mipro_banking77/run.exs"

  test "retained ordinary run preserves search, untouched, and fresh-process boundaries" do
    result = @result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"
    assert result["split_sizes"] == %{"train" => 16, "selection" => 8, "untouched_test" => 40}
    assert result["search"]["trial_scores"] == [0.625, 0.5]
    assert result["search"]["selected"] == "baseline"
    assert result["search"]["logical_calls"] == result["search"]["transport_attempts"]
    assert result["untouched_test"]["baseline"] == result["untouched_test"]["selected"]
    assert result["fresh_process"]["byte_identical"]
    assert result["fresh_process"]["logical_calls"] == 40
    assert result["claim_boundary"] =~ "not general MIPROv2 effectiveness"
  end

  test "front door keeps test rows outside optimization and uses a portable parameter artifact" do
    source = File.read!(@source)

    assert source =~ "Imp.optimize!(baseline, &1, examples(rows.train), examples(rows.selection))"
    refute source =~ "Imp.optimize!(baseline, &1, examples(rows.test)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Artifact.apply(program!(job, observer))"
    assert source =~ "IMP_MIPRO_FRESH"
  end
end
