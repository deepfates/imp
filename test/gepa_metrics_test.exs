defmodule GepaMetricsTest do
  use ExUnit.Case, async: true

  test "AIME metric parses integer answers exactly" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "AIME.metric integer exact match",
        "output_key" => "answer"
      })

    example = DSEx.example(problem: "p", answer: "42") |> DSEx.with_inputs(:problem)

    assert metric.(example, DSEx.prediction(answer: "42"))
    refute metric.(example, DSEx.prediction(answer: "42.0"))
    refute metric.(example, DSEx.prediction(answer: "forty two"))
  end

  test "HotPotQA metric uses normalized exact match over answer aliases" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "dspy.evaluate.answer_exact_match",
        "output_key" => "answer"
      })

    example =
      DSEx.example(question: "q", answer: ["The Eiffel Tower", "Eiffel Tower"])
      |> DSEx.with_inputs(:question)

    assert metric.(example, DSEx.prediction(answer: "eiffel tower"))
    refute metric.(example, DSEx.prediction(answer: "Paris"))
  end

  test "HoVer metric checks supporting fact titles against retrieved documents" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "hover_utils.discrete_retrieval_eval",
        "output_key" => "label"
      })

    example =
      DSEx.example(
        claim: "c",
        supporting_facts: [%{"key" => "Alpha Page"}, %{"key" => "Beta Page"}],
        label: "SUPPORTED"
      )
      |> DSEx.with_inputs(:claim)

    assert metric.(
             example,
             DSEx.prediction(retrieved_docs: ["Alpha Page | text", "Beta Page | text"])
           )

    refute metric.(example, DSEx.prediction(retrieved_docs: ["Alpha Page | text"]))
  end

  test "unknown GEPA metric falls back to normalized output exact match" do
    metric =
      DSEx.BenchmarkTruth.GepaMetrics.metric(%{
        "upstream_metric" => "unknown",
        "output_key" => "response"
      })

    example = DSEx.example(prompt: "p", response: "Hello, world!") |> DSEx.with_inputs(:prompt)

    assert metric.(example, DSEx.prediction(response: "hello world"))
  end
end
