defmodule AutoEvaluationFidelityTest do
  use ExUnit.Case, async: true

  alias DSEx.Evaluate.{CompleteAndGrounded, SemanticF1}

  test "SemanticF1 computes the clamped harmonic mean locally" do
    lm = static_lm(fn _prompt -> %{reasoning: "judge", precision: 0.8, recall: 0.6} end)

    assert {:ok, result} =
             SemanticF1.new(lm: lm)
             |> SemanticF1.call(%{
               question: "q",
               ground_truth: "gold",
               system_response: "response"
             })

    assert_in_delta result.score, 0.6857142857, 1.0e-9
    assert_in_delta DSEx.Prediction.get(result, :f1), 0.6857142857, 1.0e-9

    assert {:ok, clamped} = SemanticF1.f1_score(2.0, 0.5)
    assert_in_delta clamped, 2 / 3, 1.0e-9
    assert {:ok, zero} = SemanticF1.f1_score(-1, 0.5)
    assert zero == 0.0
  end

  test "SemanticF1 uses threshold truth only when a trace is supplied" do
    lm = static_lm(fn _prompt -> %{reasoning: "judge", precision: 0.8, recall: 0.6} end)

    assert {:ok, result} =
             SemanticF1.new(lm: lm, threshold: 0.7)
             |> SemanticF1.call(%{
               question: "q",
               ground_truth: "gold",
               system_response: "response",
               trace: []
             })

    assert result.score == false
    assert DSEx.Prediction.get(result, :score) == false
    assert is_float(DSEx.Prediction.get(result, :f1))
  end

  test "decompositional SemanticF1 requests key-idea fields" do
    parent = self()

    lm =
      static_lm(fn prompt ->
        send(parent, {:prompt, prompt})

        %{
          reasoning: "judge",
          ground_truth_key_ideas: "a",
          system_response_key_ideas: "a",
          discussion: "same",
          precision: 1,
          recall: 1
        }
      end)

    assert {:ok, %{score: 1.0}} =
             SemanticF1.new(lm: lm, decompositional: true)
             |> SemanticF1.call(%{question: "q", ground_truth: "a", system_response: "a"})

    assert_received {:prompt, prompt}
    assert prompt =~ "ground_truth_key_ideas"
    assert prompt =~ "system_response_key_ideas"
  end

  test "CompleteAndGrounded performs independent judgments and combines them" do
    parent = self()

    lm =
      static_lm(fn prompt ->
        send(parent, {:prompt, prompt})

        if prompt =~ "completeness" do
          %{
            reasoning: "complete",
            ground_truth_key_ideas: "a",
            system_response_key_ideas: "a",
            discussion: "mostly",
            completeness: 0.9
          }
        else
          %{
            reasoning: "grounded",
            system_response_claims: "a",
            discussion: "supported",
            groundedness: 0.8
          }
        end
      end)

    assert {:ok, result} =
             CompleteAndGrounded.new(lm: lm, threshold: 0.85)
             |> CompleteAndGrounded.call(%{
               example: DSEx.example(question: "q", response: "gold"),
               pred: DSEx.prediction(response: "answer", context: "context"),
               trace: :optimizer
             })

    assert result.score == false
    assert_in_delta DSEx.Prediction.get(result, :f1), 0.8470588235, 1.0e-9
    assert_received {:prompt, completeness_prompt}
    assert_received {:prompt, groundedness_prompt}
    assert completeness_prompt =~ "ground_truth"
    assert groundedness_prompt =~ "retrieved_context"
  end

  test "auto evaluators fail closed on missing or nonnumeric judgment fields" do
    missing = static_lm(fn _prompt -> %{reasoning: "judge", precision: "high", recall: 1} end)

    assert {:error, %{reason: {:error, %DSEx.AdapterParseError{}}}} =
             SemanticF1.new(lm: missing)
             |> SemanticF1.call(%{question: "q", ground_truth: "a", system_response: "a"})
  end

  defp static_lm(handler) do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          messages |> Enum.map_join("\n", & &1.content) |> handler.()
        end
      ]
    }
  end
end
