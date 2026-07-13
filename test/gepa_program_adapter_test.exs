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
end
