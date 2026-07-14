defmodule Imp.ConfidenceTest do
  use ExUnit.Case, async: true

  test "feedback preserves upstream buckets and considers at most three alternatives" do
    alternatives = [
      %{token: "Food", resolved_value: "Food", raw_confidence: 0.8},
      %{token: "Dr", resolved_value: "Drinks", raw_confidence: 0.1},
      %{token: "Ot", resolved_value: "Other", raw_confidence: 0.05},
      %{token: "Late", resolved_value: "Late", raw_confidence: 0.04}
    ]

    assert Imp.Confidence.feedback(true, "Food", "Food", :math.log(0.995), [], %{}, 0.99, 0.5) ==
             "Correct."

    medium =
      Imp.Confidence.feedback(
        true,
        "Food",
        "Food",
        :math.log(0.8),
        alternatives,
        %{},
        0.99,
        0.5
      )

    assert medium =~ "Correct (80% probability)."
    assert medium =~ "Drinks"
    assert medium =~ "Other"
    refute medium =~ "Late"

    low =
      Imp.Confidence.feedback(
        true,
        "Food",
        "Food",
        :math.log(0.2),
        alternatives,
        %{},
        0.99,
        0.5
      )

    assert low =~ "Correct but uncertain"

    high_wrong =
      Imp.Confidence.feedback(
        false,
        "Food",
        "Drinks",
        :math.log(0.995),
        alternatives,
        %{},
        0.99,
        0.5
      )

    assert high_wrong =~ "WRONG"
    assert high_wrong =~ "actively misleading"

    medium_wrong =
      Imp.Confidence.feedback(false, "Food", "Drinks", :math.log(0.7), [], %{}, 0.99, 0.5)

    assert medium_wrong =~ "Wrong (70% probability)"

    low_wrong =
      Imp.Confidence.feedback(false, "Food", "Drinks", :math.log(0.2), [], %{}, 0.99, 0.5)

    assert low_wrong =~ "model was uncertain"
  end

  test "missing capability fails closed unless accuracy fallback is explicit" do
    example = Imp.example(input: "lunch", answer: "Food") |> Imp.with_inputs(:input)

    prediction =
      Imp.Prediction.new(%{category: "Food"},
        metadata: %{req_llm: %{provider: "anthropic", api: nil, logprobs: []}}
      )

    failed =
      Imp.Confidence.evaluate(example, prediction,
        field: :category,
        enum: ["Food", "Drinks"]
      )

    assert failed.score == 0.0

    assert failed.metadata.imp_metric_error ==
             {:confidence_unavailable, :anthropic_unsupported}

    refute Map.has_key?(failed.metadata, :objective_scores)

    fallback =
      Imp.Confidence.evaluate(example, prediction,
        field: :category,
        enum: ["Food", "Drinks"],
        fallback: :accuracy
      )

    assert fallback.score == 1.0
    assert fallback.metadata.objective_scores == %{accuracy: 1.0}
    refute Map.has_key?(fallback.metadata.objective_scores, :raw_confidence)
    refute Map.has_key?(fallback.metadata.objective_scores, :confidence_quality)

    assert fallback.metadata.confidence == %{
             available?: false,
             fallback: :accuracy,
             reason: :anthropic_unsupported
           }
  end

  test "failed overlap is not projected as zero raw confidence" do
    content = ~s({"category":""})
    example = Imp.example(input: "blank", answer: "") |> Imp.with_inputs(:input)

    prediction =
      Imp.Prediction.new(%{category: ""},
        metadata: %{
          req_llm: %{
            provider: "openai",
            api: "chat_completions",
            content: content,
            logprobs: [%{token: content, logprob: -0.2, top_logprobs: []}]
          }
        }
      )

    result = Imp.Confidence.evaluate(example, prediction, field: :category, enum: [""])

    assert result.metadata.imp_metric_error ==
             {:confidence_unavailable,
              {:logprob_extraction_failed, :no_overlapping_logprob_tokens}}

    refute Map.has_key?(result.metadata, :objective_scores)

    fallback =
      Imp.Confidence.evaluate(example, prediction,
        field: :category,
        enum: [""],
        fallback: :accuracy
      )

    assert fallback.metadata.objective_scores == %{accuracy: 1.0}
    refute Map.has_key?(fallback.metadata.objective_scores, :raw_confidence)
    refute Map.has_key?(fallback.metadata.objective_scores, :confidence_quality)

    assert fallback.metadata.confidence.reason ==
             {:logprob_extraction_failed, :no_overlapping_logprob_tokens}
  end
end
