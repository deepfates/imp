defmodule EvaluateMetricTraceTest do
  use ExUnit.Case, async: true

  # DSPy's switch: a metric's trace is nil at evaluation and the program's trace
  # while an optimizer bootstraps. Ported metrics branch on it, scoring
  # continuously when evaluated and passing or failing demos when compiling.

  defp program do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)
    Imp.predict("question -> answer", lm: lm)
  end

  defp recording_metric(owner) do
    fn example, prediction, trace ->
      send(owner, {:trace, trace})
      Imp.get(example, :answer) == Imp.get(prediction, :answer)
    end
  end

  defp devset, do: [Imp.example(question: "Capital of France?", answer: "Paris")]

  test "evaluation passes nil as the trace" do
    result = Imp.evaluate(program(), devset(), recording_metric(self()))
    assert result.score > 0
    assert_received {:trace, nil}
  end

  test "bootstrapping passes the program's trace" do
    optimizer = Imp.Optimizer.BootstrapFewShot.new(recording_metric(self()))
    assert {:ok, _compiled} = Imp.optimize(program(), optimizer, devset())
    assert_received {:trace, trace} when trace != nil
  end
end
