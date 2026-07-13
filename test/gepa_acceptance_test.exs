defmodule DSEx.Optimizer.GEPA.AcceptanceTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Acceptance, Result}

  test "mutation defaults to strict summed-score improvement" do
    before = result([0.4, 0.6])

    assert Acceptance.default(:mutation) == :strict_improvement
    assert Acceptance.accept?(:strict_improvement, before, result([0.5, 0.6]))
    refute Acceptance.accept?(:strict_improvement, before, result([0.5, 0.5]))
    refute Acceptance.accept?(:strict_improvement, before, result([0.3, 0.6]))
  end

  test "merge defaults to equal-or-better acceptance" do
    before = result([0.4, 0.6])

    assert Acceptance.default(:merge) == :equal_or_better

    assert {:accept, :equal_or_better} =
             Acceptance.decide(:equal_or_better, before, result([0.5, 0.5]), %{
               operation: :merge
             })

    assert {:reject, :worse_score} =
             Acceptance.decide(:equal_or_better, before, result([0.4, 0.5]), %{
               operation: :merge
             })
  end

  test "callback receives full before and after results plus caller context" do
    before =
      Result.new([:old], [0.5],
        objective_scores: [%{accuracy: 0.4}],
        trajectories: %{main: [nil]},
        side_information: %{main: [:old_feedback]},
        metadata: %{phase: :before}
      )

    after_result =
      Result.new([:new], [0.5],
        objective_scores: [%{accuracy: 0.7}],
        trajectories: %{main: [nil]},
        side_information: %{main: [:new_feedback]},
        metadata: %{phase: :after}
      )

    policy =
      Acceptance.callback(fn context ->
        assert context.operation == :mutation
        assert context.candidate == %{main: "proposal"}
        assert context.before == before
        assert context.after == after_result
        assert context.before_score == 0.5
        assert context.after_score == 0.5
        assert context.before.outputs == [:old]
        assert context.after.objective_scores == [%{accuracy: 0.7}]
        {:accept, :accuracy_improved}
      end)

    assert {:accept, :accuracy_improved} =
             Acceptance.decide(policy, before, after_result, %{
               operation: :mutation,
               candidate: %{main: "proposal"}
             })
  end

  test "reserved callback fields cannot be replaced by caller context" do
    before = result([0.1])
    after_result = result([0.2])

    policy =
      Acceptance.callback(fn context ->
        assert context.before == before
        assert context.after == after_result
        assert context.before_score == 0.1
        true
      end)

    assert Acceptance.accept?(policy, before, after_result, %{
             before: :spoofed,
             after: :spoofed,
             before_score: 100
           })
  end

  test "callback decisions are normalized and invalid decisions fail loudly" do
    before = result([0.0])
    after_result = result([1.0])

    assert {:reject, :policy_reason} =
             Acceptance.decide(
               Acceptance.callback(fn _ -> {:reject, :policy_reason} end),
               before,
               after_result
             )

    assert_raise ArgumentError, ~r/acceptance callback must return/, fn ->
      Acceptance.decide(Acceptance.callback(fn _ -> :maybe end), before, after_result)
    end
  end

  defp result(scores), do: Result.new(scores, scores)
end
