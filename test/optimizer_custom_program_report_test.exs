defmodule Imp.OptimizerCustomProgramReportTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{Artifact, Report}
  alias Imp.TestSupport.TwoStageOptimizerProgram

  test "shared attachment retains one report on a custom multi-predictor program" do
    program = TwoStageOptimizerProgram.new(Imp.LM.Static.new())
    report = Report.new(optimizer: :simba, best_score: 0.75)

    attached = Report.attach(program, report)

    assert Report.fetch(attached) == report

    assert Enum.all?(Imp.ProgramParameters.predictors(attached), fn %{predictor: predictor} ->
             Imp.ProgramAccess.get_metadata(predictor, :optimizer_report) == report
           end)
  end

  test "conflicting predictor reports fail loudly" do
    first = Report.new(optimizer: :mipro_v2, best_score: 0.25)
    second = Report.new(optimizer: :mipro_v2, best_score: 0.75)

    program =
      TwoStageOptimizerProgram.new(Imp.LM.Static.new())
      |> Imp.ProgramParameters.update_predictor(:analyze_intent, fn predictor ->
        Imp.ProgramAccess.put_metadata(predictor, :optimizer_report, first)
      end)
      |> Imp.ProgramParameters.update_predictor(:classify_route, fn predictor ->
        Imp.ProgramAccess.put_metadata(predictor, :optimizer_report, second)
      end)

    assert_raise ArgumentError, "program predictors carry conflicting optimizer reports", fn ->
      Report.fetch(program)
    end
  end

  test "GEPA no longer needs an out-of-band report to expose custom-program selection" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)
          if String.contains?(rendered, "`route`"), do: %{route: "R42"}, else: %{evidence: "x"}
        end
      )

    program = TwoStageOptimizerProgram.new(lm)

    example =
      Imp.example(utterance: "unknown payment", route: "R42") |> Imp.with_inputs(:utterance)

    metric = fn expected, prediction ->
      Imp.get(expected, :route) == Imp.get(prediction, :route)
    end

    {compiled, report} =
      Imp.Optimizer.GEPA.new(metric, generations: 0)
      |> Imp.Optimizer.GEPA.compile_with_report(program, [example], [example])

    assert Report.fetch(compiled) == report
    assert report.best_score == 1.0
  end

  test "SIMBA returns its final report from a custom multi-predictor program" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)
          if String.contains?(rendered, "`route`"), do: %{route: "R42"}, else: %{evidence: "x"}
        end
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> %{discussion: "unused", module_advice: %{}} end
      )

    program = TwoStageOptimizerProgram.new(lm)

    example =
      Imp.example(utterance: "unknown payment", route: "R42") |> Imp.with_inputs(:utterance)

    metric = fn expected, prediction ->
      Imp.get(expected, :route) == Imp.get(prediction, :route)
    end

    compiled =
      Imp.Optimizer.SIMBA.new(metric,
        bsize: 1,
        num_candidates: 1,
        max_steps: 0,
        prompt_lm: prompt_lm
      )
      |> Imp.Optimizer.SIMBA.compile(program, [example], [example])

    assert %Report{optimizer: :simba, best_score: 1.0} = Report.fetch(compiled)

    assert Enum.all?(Imp.ProgramParameters.predictors(compiled), fn %{predictor: predictor} ->
             match?(%Report{optimizer: :simba}, Report.fetch(predictor))
           end)

    artifact =
      Artifact.from_optimized_program(compiled,
        artifact_id: "simba-router-v1",
        provenance: %{split: "final"}
      )

    assert %{
             champion_id: "simba-router-v1",
             candidates: [%{"score" => 1.0}],
             provenance: %{"optimizer" => "simba", "split" => "final"}
           } = Artifact.inspect(artifact)

    fresh = TwoStageOptimizerProgram.new(lm)
    applied = Artifact.apply(artifact, fresh)
    assert Report.fetch(applied) == nil
    assert {:ok, prediction} = Imp.call(applied, %{utterance: "unknown payment"})
    assert Imp.get(prediction, :route) == "R42"
  end

  test "shared artifact capture rejects missing reports and unsupported options" do
    program = TwoStageOptimizerProgram.new(Imp.LM.Static.new())

    assert_raise ArgumentError, ~r/does not carry an Imp optimizer report/, fn ->
      Artifact.from_optimized_program(program)
    end

    attached = Report.attach(program, Report.new(optimizer: :mipro_v2, best_score: 0.5))

    assert_raise ArgumentError, ~r/unknown .* options.*executable/, fn ->
      Artifact.from_optimized_program(attached, executable: true)
    end
  end
end
