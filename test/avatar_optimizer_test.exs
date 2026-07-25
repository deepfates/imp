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

  test "minimization does not promote a candidate whose calls failed" do
    actor_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "Break every actor call." ->
              raise "rewritten actor failed"

            prompt =~ "Do not request another tool." ->
              if prompt =~ "expensive",
                do: %{answer: "expensive"},
                else: %{answer: "cheap"}

            prompt =~ "tool_output:" ->
              %{action: %{tool_name: "Finish", tool_input_query: %{}}}

            prompt =~ "expensive" ->
              %{action: %{tool_name: "lookup", tool_input_query: %{query: "offline"}}}

            true ->
              %{action: %{tool_name: "Finish", tool_input_query: %{}}}
          end
        end
      )

    lookup = Imp.tool(:lookup, "lookup", fn _arguments -> {:error, :offline} end)
    student = Imp.avatar("question -> answer", [lookup], lm: actor_lm, max_iters: 2)

    trainset = [
      Imp.example(question: "cheap train case", answer: "cheap") |> Imp.with_inputs(:question),
      Imp.example(question: "expensive train case", answer: "expensive")
      |> Imp.with_inputs(:question)
    ]

    cost = fn _example, prediction ->
      if Imp.get(prediction, :answer) == "cheap", do: 0.0, else: 1.0
    end

    optimizer =
      Imp.Optimizer.Avatar.new(cost,
        max_iters: 1,
        optimize_for: :min,
        comparator_lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts -> %{feedback: "Replace the instruction."} end
          ),
        rewrite_lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts -> %{new_instruction: "Break every actor call."} end
          )
      )

    compiled = Imp.optimize!(student, optimizer, trainset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.best_score == 0.5

    assert [%{baseline: true, selected?: true}, failed_candidate] = report.candidates
    assert failed_candidate.score == 0.0
    refute failed_candidate.selected?

    assert Enum.count(report.errors, fn error ->
             error.iteration == 1 and error.stage == :evaluation
           end) == 2

    refute Imp.Predict.Avatar.current_instruction(compiled) == "Break every actor call."

    assert {:ok, held_out} = Imp.call(compiled, %{question: "heldout expensive case"})
    assert Imp.get(held_out, :answer) == "expensive"

    assert [
             %Imp.Predict.Avatar.ActionOutput{
               tool_output: {:error, :offline},
               error?: true
             }
           ] = Imp.get(held_out, :actions)
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
