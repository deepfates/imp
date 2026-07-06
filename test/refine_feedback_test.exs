defmodule RefineFeedbackTest do
  use ExUnit.Case

  defmodule HintProgram do
    defstruct []

    def call(%__MODULE__{}, inputs) do
      answer = if Map.get(Map.new(inputs), :hint_), do: "fixed", else: "bad"
      {:ok, DSEx.Prediction.new(%{answer: answer})}
    end
  end

  test "Refine injects feedback hints from prior attempts" do
    metric = fn _example, prediction -> DSEx.Prediction.get(prediction, :answer) == "fixed" end
    feedback = fn history -> "repair after #{length(history)} miss" end

    assert {:ok, prediction} =
             DSEx.Predict.Refine.new(%HintProgram{}, metric,
               max_attempts: 2,
               feedback_fn: feedback
             )
             |> DSEx.Predict.Refine.call(%{question: "q"})

    assert DSEx.Prediction.get(prediction, :answer) == "fixed"
  end

  test "BestOfN attaches comparison feedback to selected prediction" do
    program = %HintProgram{}

    metric = fn _example, prediction ->
      if DSEx.Prediction.get(prediction, :answer) == "bad", do: 0.0, else: 1.0
    end

    feedback = fn predictions -> "compared #{length(predictions)} attempts" end

    assert {:ok, prediction} =
             DSEx.Predict.BestOfN.new(program, metric, n: 2, feedback_fn: feedback)
             |> DSEx.Predict.BestOfN.call(%{})

    assert DSEx.Prediction.get(prediction, :feedback) == "compared 2 attempts"
  end
end
