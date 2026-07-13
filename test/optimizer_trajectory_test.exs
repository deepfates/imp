defmodule DSEx.Optimizer.TrajectoryTest do
  use ExUnit.Case, async: true

  defmodule TwoStage do
    defstruct [:first, :second, fail_after_first: false]

    def optimizer_predictors(program), do: [hint: program.first, answer: program.second]

    def update_optimizer_predictor(program, :hint, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :answer, update),
      do: %{program | second: update.(program.second)}

    def call(program, inputs) do
      with {:ok, hint} <- DSEx.Predict.Predict.call(program.first, inputs) do
        if program.fail_after_first do
          {:error, :forced_second_stage_failure}
        else
          DSEx.Predict.Predict.call(program.second, %{
            question: Map.fetch!(inputs, :question),
            hint: DSEx.get(hint, :hint)
          })
        end
      end
    end
  end

  test "captures ordered named predictor calls" do
    program = program(false)
    example = DSEx.example(question: "France?", answer: "Paris") |> DSEx.with_inputs(:question)

    [trajectory] =
      DSEx.Optimizer.TrajectoryRunner.run(
        program,
        [example],
        DSEx.Metrics.exact_match(:answer)
      )

    assert trajectory.score == 1.0
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint, :answer]
    assert hd(trajectory.trace).outputs == %{hint: "capital clue"}
    assert List.last(trajectory.trace).inputs.hint == "capital clue"
  end

  test "retains partial module traces when a later stage fails" do
    example = DSEx.example(question: "France?", answer: "Paris") |> DSEx.with_inputs(:question)

    [trajectory] =
      DSEx.Optimizer.TrajectoryRunner.run(
        program(true),
        [example],
        DSEx.Metrics.exact_match(:answer)
      )

    assert trajectory.error == :forced_second_stage_failure
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint]
  end

  test "runs the metric after failure and keeps prediction-valued diagnostics" do
    example = DSEx.example(question: "France?", answer: "Paris") |> DSEx.with_inputs(:question)

    metric = fn _example, nil, trace ->
      DSEx.Prediction.new(%{
        score: 0.25,
        diagnosis: "recoverable",
        trace_size: length(trace)
      })
    end

    [trajectory] = DSEx.Optimizer.TrajectoryRunner.run(program(true), [example], metric)

    assert trajectory.error == :forced_second_stage_failure
    assert trajectory.score == 0.25
    assert trajectory.metric_metadata.diagnosis == "recoverable"
    assert trajectory.metric_metadata.trace_size == 1
  end

  defp program(fail_after_first) do
    hint_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{hint: "capital clue"} end]
    }

    answer_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    %TwoStage{
      first: DSEx.predict("question -> hint", lm: hint_lm),
      second: DSEx.predict("question, hint -> answer", lm: answer_lm),
      fail_after_first: fail_after_first
    }
  end
end
