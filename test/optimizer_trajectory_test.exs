defmodule Imp.Optimizer.TrajectoryTest do
  use ExUnit.Case, async: true

  defmodule TwoStage do
    defstruct [:first, :second, fail_after_first: false]

    def optimizer_predictors(program), do: [hint: program.first, answer: program.second]

    def update_optimizer_predictor(program, :hint, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :answer, update),
      do: %{program | second: update.(program.second)}

    def call(program, inputs) do
      with {:ok, hint} <- Imp.Predict.Predict.call(program.first, inputs) do
        if program.fail_after_first do
          {:error, :forced_second_stage_failure}
        else
          Imp.Predict.Predict.call(program.second, %{
            question: Map.fetch!(inputs, :question),
            hint: Imp.get(hint, :hint)
          })
        end
      end
    end
  end

  test "captures ordered named predictor calls" do
    program = program(false)
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    [trajectory] =
      Imp.Optimizer.TrajectoryRunner.run(
        program,
        [example],
        Imp.Metrics.exact_match(:answer)
      )

    assert trajectory.score == 1.0
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint, :answer]
    assert hd(trajectory.trace).outputs == %{hint: "capital clue"}
    assert List.last(trajectory.trace).inputs.hint == "capital clue"
  end

  test "retains partial module traces when a later stage fails" do
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    [trajectory] =
      Imp.Optimizer.TrajectoryRunner.run(
        program(true),
        [example],
        Imp.Metrics.exact_match(:answer)
      )

    assert trajectory.error == :forced_second_stage_failure
    assert Enum.map(trajectory.trace, & &1.predictor) == [:hint]
  end

  test "runs the metric after failure and keeps prediction-valued diagnostics" do
    example = Imp.example(question: "France?", answer: "Paris") |> Imp.with_inputs(:question)

    metric = fn _example, nil, trace ->
      Imp.Prediction.new(%{
        score: 0.25,
        diagnosis: "recoverable",
        trace_size: length(trace)
      })
    end

    [trajectory] = Imp.Optimizer.TrajectoryRunner.run(program(true), [example], metric)

    assert trajectory.error == :forced_second_stage_failure
    assert trajectory.score == 0.25
    assert trajectory.metric_metadata.diagnosis == "recoverable"
    assert trajectory.metric_metadata.trace_size == 1
  end

  defp program(fail_after_first) do
    hint_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{hint: "capital clue"} end]
    }

    answer_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    %TwoStage{
      first: Imp.predict("question -> hint", lm: hint_lm),
      second: Imp.predict("question, hint -> answer", lm: answer_lm),
      fail_after_first: fail_after_first
    }
  end
end
