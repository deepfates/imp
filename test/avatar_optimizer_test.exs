defmodule AvatarOptimizerTest do
  use ExUnit.Case, async: true

  test "rewrites instructions from positive and negative action trajectories" do
    lookup = Imp.tool(:lookup, "Look up a country capital", &lookup/1)
    student = Imp.avatar("question -> answer", [lookup], lm: avatar_lm(), max_iters: 2)

    trainset = [
      Imp.example(question: "easy", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "hard", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    optimizer =
      Imp.Optimizer.Avatar.new(Imp.exact_match(:answer),
        max_iters: 1,
        comparator_lm: static_lm(%{feedback: "Use the exact country name for lookup."}),
        rewrite_lm:
          static_lm(%{
            new_instruction:
              "Use exact country names with lookup, then select Finish after a successful result."
          })
      )

    compiled = Imp.optimize!(student, optimizer, trainset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :avatar
    assert report.best_score == 1.0
    assert report.candidate_count == 2
    assert report.errors == []
    assert report.metadata.stop_reason == :max_iters

    assert [%{baseline: true, score: 0.5}, %{baseline: false, score: 1.0, selected?: true}] =
             report.candidates

    assert [round] = report.metadata.rounds
    assert round.positive_count == 1
    assert round.negative_count == 1
    assert round.feedback == "Use the exact country name for lookup."

    assert Imp.Predict.Avatar.current_instruction(compiled) =~ "exact country names"
    assert {:ok, prediction} = Imp.call(compiled, %{question: "hard"})
    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "missing trajectory class returns executable baseline with diagnostic report" do
    student =
      Imp.avatar("question -> answer", [],
        lm:
          static_lm(fn prompt ->
            if prompt =~ "Do not request another tool.",
              do: %{answer: "Paris"},
              else: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
          end)
      )

    trainset = [Imp.example(question: "q", answer: "Paris") |> Imp.with_inputs(:question)]

    optimizer =
      Imp.Optimizer.Avatar.new(Imp.exact_match(:answer),
        max_iters: 2,
        lm: static_lm(%{feedback: "unused", new_instruction: "unused"})
      )

    compiled = Imp.optimize!(student, optimizer, trainset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.best_score == 1.0
    assert report.metadata.stop_reason == :no_negative_examples
    assert [%{stage: :classification, reason: :no_negative_examples}] = report.errors
    assert {:ok, prediction} = Imp.call(compiled, %{question: "q"})
    assert Imp.get(prediction, :answer) == "Paris"
  end

  defp avatar_lm do
    static_lm(fn prompt ->
      cond do
        prompt =~ "Do not request another tool." ->
          if prompt =~ "tool_output: \"Paris\"",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}

        prompt =~ "tool_output:" ->
          %{action: %{tool_name: "Finish", tool_input_query: %{}}}

        prompt =~ "[[ ## question ## ]]\nhard" and prompt =~ "exact country names" ->
          %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}

        prompt =~ "[[ ## question ## ]]\nhard" ->
          %{action: %{tool_name: "lookup", tool_input_query: %{country: "wrong"}}}

        true ->
          %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}
      end
    end)
  end

  defp lookup(%{country: "France"}), do: "Paris"
  defp lookup(_), do: "unknown"

  defp static_lm(handler) when is_function(handler, 1) do
    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts -> handler.(Enum.map_join(messages, "\n", & &1.content)) end
      ]
    }
  end

  defp static_lm(response), do: static_lm(fn _prompt -> response end)
end
