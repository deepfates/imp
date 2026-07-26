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

  test "demo-only selection is mutated and its artifact matches the selected finalist" do
    lm = Imp.LM.Static.new()
    baseline = Imp.predict("question -> answer", lm: lm)

    demo =
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.with_inputs(:question)

    selected = Imp.Predict.Predict.with_demos(baseline, [demo])

    selected_parameters =
      apply(LocalSIMBABanking77.Audit, :parameter_snapshot, [selected])

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :simba,
        best_score: 1.0,
        metadata: %{
          final_candidates: [
            %{finalist_index: 0, score: 0.0, parameters: []},
            %{finalist_index: 1, score: 1.0, parameters: selected_parameters}
          ]
        }
      })

    selected = Imp.Optimizer.Report.attach(selected, report)

    artifact =
      Imp.Optimizer.Artifact.from_optimized_program(selected,
        artifact_id: "simba-demo-only"
      )

    assert apply(LocalSIMBABanking77.Audit, :selection_kind, [baseline, selected]) == "mutated"

    assert :ok =
             apply(LocalSIMBABanking77.Audit, :verify_selected_artifact!, [
               artifact,
               baseline,
               selected,
               report
             ])

    mismatched_report =
      put_in(report.metadata.final_candidates, [
        %{finalist_index: 0, score: 1.0, parameters: []}
      ])

    assert_raise RuntimeError, ~r/does not match a best-scoring SIMBA finalist/, fn ->
      apply(LocalSIMBABanking77.Audit, :verify_selected_artifact!, [
        artifact,
        baseline,
        selected,
        mismatched_report
      ])
    end
  end
end
