defmodule Imp.LocalSIMBABanking77ExampleTest do
  use ExUnit.Case, async: true

  @source "examples/local_simba_banking77/run.exs"

  test "front door keeps untouched rows outside SIMBA and uses the selected artifact" do
    source = File.read!(@source)

    assert source =~ "SIMBA.compile(baseline, examples(rows.train), examples(rows.selection))"
    refute source =~ "SIMBA.compile(baseline, examples(rows.test)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Artifact.apply(program!(job, observer))"
    assert source =~ "IMP_SIMBA_FRESH"
  end

  test "front door rejects candidate-count and cached-call substitutes" do
    source = File.read!(@source)

    assert source =~ "stage.rendered_mutation_calls > 0"
    assert source =~ "stage.mutated_candidates > 0"
    assert source =~ "max_demos: 4"
    assert source =~ "cache: false"
    assert source =~ "stage.logical_calls == 40 and stage.transport_attempts == 40"
  end
end
