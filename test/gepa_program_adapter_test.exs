defmodule DSEx.Optimizer.GEPA.ProgramAdapterTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Adapter, Candidate, Evaluation, ProgramAdapter}

  test "runs a real DSEx program and produces component reflection records" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    metric = fn example, prediction, _trace ->
      %{
        score:
          if(DSEx.Prediction.get(prediction, :answer) == DSEx.Example.get(example, :answer),
            do: 1.0,
            else: 0.0
          ),
        feedback: "Expected #{DSEx.Example.get(example, :answer)}"
      }
    end

    adapter = ProgramAdapter.new(program, metric)
    candidate = Candidate.from_program(program)

    batch = [
      %{question: "Capital of France?", answer: "Paris"}
      |> DSEx.Example.new()
      |> DSEx.Example.with_inputs([:question])
    ]

    result = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    assert result.scores == [1.0]
    assert result.metadata.metric_calls == 1
    assert [%DSEx.Optimizer.Trajectory{}] = result.trajectories.main

    assert %{main: [record]} =
             Adapter.make_reflective_dataset(adapter, candidate, result, [:main])

    assert record["Inputs"] == %{question: "Capital of France?"}
    assert record["Generated Outputs"] == %{answer: "Paris"}
    assert record["Feedback"] =~ "Expected Paris"
  end

  test "uses named component feedback only for reflective evaluations" do
    owner = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)
    metric = fn _example, _prediction -> %{score: 0.5, feedback: "metric feedback"} end

    callback = fn context ->
      send(owner, {:component_feedback, context})
      %{feedback_text: "Inspect #{context.predictor_output.answer}"}
    end

    adapter = ProgramAdapter.new(program, metric, component_feedback: %{main: callback})
    candidate = Candidate.from_program(program)

    batch = [
      %{question: "Capital of France?", answer: "Paris"}
      |> DSEx.Example.new()
      |> DSEx.Example.with_inputs([:question])
    ]

    ordinary = Evaluation.evaluate(adapter, batch, candidate)
    refute_received {:component_feedback, _context}
    assert ordinary.side_information.main == ["metric feedback"]

    reflective = Evaluation.evaluate(adapter, batch, candidate, capture_traces: true)

    assert_receive {:component_feedback, context}
    assert context.component == :main
    assert context.predictor_inputs == %{question: "Capital of France?"}
    assert context.predictor_output == %{answer: "Paris"}
    assert context.score == 0.5

    assert %{main: [%{"Feedback" => feedback}]} =
             Adapter.make_reflective_dataset(adapter, candidate, reflective, [:main])

    assert feedback =~ "Inspect Paris"
  end

  test "rejects unknown callbacks and fails closed when callback execution breaks" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "x"} end]}
    program = DSEx.predict("question -> answer", lm: lm)
    metric = fn _example, _prediction -> 1.0 end

    assert_raise ArgumentError, ~r/unknown predictors: \[:missing\]/, fn ->
      ProgramAdapter.new(program, metric, component_feedback: %{missing: fn _ -> "x" end})
    end

    adapter =
      ProgramAdapter.new(program, metric,
        component_feedback: %{main: fn _context -> raise "feedback exploded" end}
      )

    batch = [DSEx.example(question: "q") |> DSEx.with_inputs(:question)]

    assert_raise RuntimeError, ~r/component feedback failed for :main: feedback exploded/, fn ->
      Evaluation.evaluate(adapter, batch, Candidate.from_program(program), capture_traces: true)
    end
  end
end
