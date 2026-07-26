defmodule Imp.Optimizer.GEPAMetricContractTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA
  alias Imp.TestSupport.TwoStageOptimizerProgram

  test "public arity-two metric executes a named two-predictor program" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          call = Process.get(:gepa_metric_contract_call, 0)
          Process.put(:gepa_metric_contract_call, call + 1)

          if rem(call, 2) == 1,
            do: %{route: "R42"},
            else: %{evidence: "unrecognized card payment"}
        end
      )

    program = TwoStageOptimizerProgram.new(lm)

    example =
      Imp.Example.new(%{utterance: "I do not recognize this card payment", route: "R42"})
      |> Imp.Example.with_inputs([:utterance])

    metric = fn received_example, prediction ->
      send(owner, {:metric_called, received_example, prediction})

      %{
        score: if(Imp.Prediction.get(prediction, :route) == "R42", do: 1.0, else: 0.0),
        feedback: "expected R42"
      }
    end

    {compiled, report} =
      GEPA.new(metric, generations: 0)
      |> GEPA.compile_with_report(program, [example], [example])

    assert_receive {:metric_called, ^example, %Imp.Prediction{} = prediction}
    assert Imp.Prediction.get(prediction, :route) == "R42"
    assert report.best_score == 1.0
    assert report.metadata.metric_calls == 1
    assert GEPA.Candidate.from_program(compiled) == GEPA.Candidate.from_program(program)
  end

  test "constructor rejects a trace-aware metric outside the documented public contract" do
    trace_aware = fn _example, _prediction, _trace -> 1.0 end

    assert_raise ArgumentError, ~r/expects a metric function with arity 2/, fn ->
      GEPA.new(trace_aware)
    end
  end
end
