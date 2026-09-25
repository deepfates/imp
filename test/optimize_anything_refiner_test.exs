defmodule Imp.Optimize.Anything.RefinerTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything.Refiner
  alias Imp.Optimize.Anything.Refiner.Result

  test "keeps strict improvements and returns the better normalized evaluation" do
    lm = static_lm([~s({"answer":"2"}), ~s({"answer":"3"})])

    evaluator = fn candidate, example ->
      score = String.to_integer(candidate.answer)
      {score, "output-#{score}-#{example}", %{feedback: "score #{score}"}}
    end

    assert %Result{} =
             result =
             execute(lm, %{answer: "1", refiner_prompt: "Increase the score."}, evaluator, 2)

    assert result.score == 3
    assert result.output == "output-3-example"
    assert result.candidate == %{answer: "3", refiner_prompt: "Increase the score."}
    assert result.asi.feedback == "score 1"
    assert Enum.map(result.attempts, & &1["score"]) == [1, 2, 3]
    assert result.asi["refiner_prompt_specific_info"]["Attempts"] == result.attempts
  end

  test "keeps original ASI while projecting winning objective scores into refiner feedback" do
    lm = static_lm([~s({"answer":"2"})])

    result =
      execute(
        lm,
        %{answer: "1", refiner_prompt: "Increase the score."},
        fn candidate ->
          score = String.to_integer(candidate.answer)
          {score, %{feedback: "original-#{score}", scores: %{quality: score / 2}}}
        end,
        1
      )

    assert result.score == 2
    assert result.asi.feedback == "original-1"
    assert result.asi.scores == %{quality: 0.5}
    assert result.asi["refiner_prompt_specific_info"]["scores"] == %{quality: 1.0}
  end

  test "stops at the first evaluated non-improvement" do
    parent = self()
    lm = static_lm([~s({"answer":"2"}), ~s({"answer":"2"}), ~s({"answer":"9"})], parent)

    result =
      execute(
        lm,
        %{answer: "1", refiner_prompt: "Increase the score."},
        fn candidate, _example ->
          {String.to_integer(candidate.answer), %{seen: candidate.answer}}
        end,
        3
      )

    assert result.score == 2
    assert Enum.map(result.attempts, & &1["score"]) == [1, 2, 2]
    assert_receive {:lm_call, 1, _prompt}
    assert_receive {:lm_call, 2, _prompt}
    refute_receive {:lm_call, 3, _prompt}
  end

  test "records malformed JSON and continues refinement" do
    lm = static_lm(["not-json", ~s({"answer":"4"})])

    result =
      execute(
        lm,
        %{answer: "1", refiner_prompt: "Increase the score."},
        fn candidate -> {String.to_integer(candidate.answer), %{candidate: candidate.answer}} end,
        2
      )

    assert result.score == 4
    assert length(result.attempts) == 3
    assert result.attempts |> Enum.at(1) |> Map.fetch!("error") =~ "JSON parse error"
    refute Map.has_key?(Enum.at(result.attempts, 1), "side_info")
  end

  test "records a redacted runtime failure and stops" do
    parent = self()
    secret = "sk-sensitive-value-123456"

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:lm_prompt, messages})
          raise "provider failed with #{secret}"
        end
      )

    result =
      execute(
        lm,
        %{answer: "1", refiner_prompt: "Increase the score."},
        fn candidate -> String.to_integer(candidate.answer) end,
        3
      )

    assert result.score == 1
    assert length(result.attempts) == 2
    error = result.attempts |> List.last() |> Map.fetch!("error")
    assert error =~ "runtime error"
    assert error =~ "[REDACTED]"
    refute error =~ secret
    assert_receive {:lm_prompt, _messages}
  end

  test "does not exceed max_refinements" do
    parent = self()
    lm = static_lm(Enum.map(2..10, &Jason.encode!(%{answer: Integer.to_string(&1)})), parent)

    result =
      execute(
        lm,
        %{answer: "1", refiner_prompt: "Increase the score."},
        fn candidate -> String.to_integer(candidate.answer) end,
        2
      )

    assert result.score == 3
    assert length(result.attempts) == 3
    assert_receive {:lm_call, 1, _prompt}
    assert_receive {:lm_call, 2, _prompt}
    refute_receive {:lm_call, 3, _prompt}
  end

  test "reports every successful original and refined evaluation" do
    receiver = self()
    lm = static_lm([~s({"answer":"2"}), "not-json", ~s({"answer":"3"})])

    result =
      Refiner.execute(
        refiner_lm: lm,
        refiner_prompt: "Increase the score.",
        max_refinements: 3,
        candidate: %{answer: "1", refiner_prompt: "Increase the score."},
        example: :example,
        evaluator: fn candidate -> String.to_integer(candidate.answer) end,
        on_evaluation: fn evaluation -> send(receiver, {:evaluation, evaluation}) end
      )

    assert result.score == 3
    assert_receive {:evaluation, %{candidate: %{answer: "1"}, score: 1}}
    assert_receive {:evaluation, %{candidate: %{answer: "2"}, score: 2}}
    assert_receive {:evaluation, %{candidate: %{answer: "3"}, score: 3}}
    refute_receive {:evaluation, _}
  end

  test "excludes the prompt component and requires every other parameter" do
    parent = self()
    lm = static_lm([~s({"first":"A2"}), ~s({"first":"A2","second":"B2"})], parent)

    candidate = %{
      first: "A1",
      second: "B1",
      refinement_instructions: "Improve both parameters."
    }

    result =
      Refiner.execute(
        refiner_lm: lm,
        refiner_prompt: candidate.refinement_instructions,
        refiner_prompt_component: :refinement_instructions,
        max_refinements: 2,
        candidate: candidate,
        example: :example,
        evaluator: fn current, _example ->
          score = if current.first == "A2" and current.second == "B2", do: 1, else: 0
          {score, %{feedback: "checked both parameters"}}
        end
      )

    assert result.score == 1
    assert result.candidate.refinement_instructions == candidate.refinement_instructions
    assert result.attempts |> Enum.at(1) |> Map.fetch!("error") =~ "JSON shape error"

    assert_receive {:lm_call, 1, first_prompt}
    assert first_prompt =~ ~s("first": "A1")
    assert first_prompt =~ ~s("second": "B1")
    refute first_prompt =~ "refinement_instructions"
  end

  defp execute(lm, candidate, evaluator, max_refinements) do
    Refiner.execute(
      refiner_lm: lm,
      refiner_prompt: candidate.refiner_prompt,
      max_refinements: max_refinements,
      candidate: candidate,
      example: :example,
      evaluator: evaluator
    )
  end

  defp static_lm(outputs, receiver \\ nil) do
    counter = start_supervised!({Agent, fn -> 0 end})

    Imp.LM.Static.new(
      handler: fn [%{content: prompt}], _opts ->
        index = Agent.get_and_update(counter, &{&1, &1 + 1})
        if receiver, do: send(receiver, {:lm_call, index + 1, prompt})
        Enum.fetch!(outputs, index)
      end
    )
  end
end
