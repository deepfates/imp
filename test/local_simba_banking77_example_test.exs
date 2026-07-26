defmodule Imp.LocalSIMBABanking77ExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_simba_banking77/run.exs"

  setup_all do
    previous = System.get_env("IMP_SIMBA_DEFINE_ONLY")
    System.put_env("IMP_SIMBA_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_SIMBA_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_SIMBA_DEFINE_ONLY")
    end)

    :ok
  end

  test "front door keeps untouched rows outside SIMBA and uses the selected artifact" do
    source = File.read!(@source)

    assert source =~ "SIMBA.compile(baseline, examples(rows.train), examples(rows.selection))"
    refute source =~ "SIMBA.compile(baseline, examples(rows.test)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Artifact.apply(program!(job, observer))"
    assert source =~ "IMP_SIMBA_FRESH"
    assert source =~ "IMP_SIMBA_SELECTED_ONLY"
  end

  test "front door rejects candidate-count and cached-call substitutes" do
    source = File.read!(@source)

    assert source =~ "Audit.valid_search?(stage)"
    assert source =~ "max_demos: 4"
    assert source =~ "cache: false"
    assert source =~ "stage.logical_calls == 40 and stage.transport_attempts == 40"
  end

  test "demo-only finalists count as real mutations" do
    finalists = [
      %{
        finalist_index: 0,
        parameters: [%{name: :main, instruction: "base", demos: []}]
      },
      %{
        finalist_index: 1,
        parameters: [%{name: :main, instruction: "base", demos: [%{utterance: "u"}]}]
      }
    ]

    assert apply(LocalSIMBABanking77.Audit, :count_mutated_finalists, [finalists, "base"]) == 1

    assert apply(LocalSIMBABanking77.Audit, :valid_search?, [
             %{
               candidate_count: 1,
               mutated_candidates: 1,
               rendered_mutation_calls: 4,
               task_transports: 12,
               reflection_transports: 0
             }
           ])

    refute apply(LocalSIMBABanking77.Audit, :valid_search?, [
             %{
               candidate_count: 1,
               mutated_candidates: 1,
               rendered_mutation_calls: 0,
               task_transports: 12,
               reflection_transports: 0
             }
           ])
  end
end
