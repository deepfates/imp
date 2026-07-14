defmodule Imp.BenchmarkTruth.HotpotFeedbackTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.HotpotFeedback
  alias Imp.Optimizer.GEPA.ComponentFeedback

  test "exposes the four source component callbacks" do
    assert HotpotFeedback.callbacks() |> Map.keys() |> Enum.sort() ==
             [:create_query_hop2, :final_answer, :summarize1, :summarize2]

    assert Enum.all?(HotpotFeedback.callbacks(), fn {_name, callback} ->
             is_function(callback, 1)
           end)
  end

  test "query feedback analyzes both retrieval hops and grades normalized EM" do
    result = HotpotFeedback.create_query_hop2(context(:create_query_hop2))

    assert result.feedback_score
    assert result.feedback_text =~ "query generation for the **second hop**"
    assert result.feedback_text =~ ~s(["Bridge"])
    assert result.feedback_text =~ ~s(["Destination"])
    assert result.feedback_text =~ "Destination | Destination contains the answer."
  end

  test "answer feedback supports multiple gold answers and output context" do
    feedback =
      context(:final_answer,
        answer: ["The Answer", "alternate"],
        predicted_answer: "answer!",
        output_feedback: "Prior program note"
      )

    result = HotpotFeedback.final_answer(feedback)

    assert result.feedback_score
    assert result.feedback_text =~ "is correct"
    assert result.feedback_text =~ "Prior program note"
    assert result.feedback_text =~ "Bridge | Bridge points onward."
  end

  test "first summary feedback includes ideal evidence and missing documents" do
    result = HotpotFeedback.summarize1(context(:summarize1))

    assert result.feedback_score
    assert result.feedback_text =~ "first-hop **summarization module**"
    assert result.feedback_text =~ "Bridge | Bridge points onward."
    assert result.feedback_text =~ "Destination | Destination contains the answer."
  end

  test "second summary feedback preserves its downstream-answer guidance" do
    result = HotpotFeedback.summarize2(context(:summarize2))

    assert result.feedback_score
    assert result.feedback_text =~ "used *directly* by the answer generation module"
    assert result.feedback_text =~ "Bridge | Bridge points onward."
    assert result.feedback_text =~ "Destination | Destination contains the answer."
  end

  test "accepts unambiguous string keys throughout the upstream example shape" do
    fields =
      example_fields()
      |> stringify_map()
      |> Map.update!("supporting_facts", &stringify_map/1)
      |> Map.update!("context", &stringify_map/1)

    feedback = %{context(:summarize1) | example: Imp.Example.new(fields)}

    assert %{feedback_text: text} = HotpotFeedback.summarize1(feedback)
    assert text != ""
  end

  test "fails closed on ambiguous atom and string keys" do
    fields = Map.put(example_fields(), "answer", "conflicting")
    feedback = %{context(:final_answer) | example: %Imp.Example{fields: fields}}

    assert_raise ArgumentError, ~r/ambiguous atom\/string keys for :answer/, fn ->
      HotpotFeedback.final_answer(feedback)
    end
  end

  test "fails closed on malformed supporting facts and sentence indices" do
    malformed =
      example_fields()
      |> put_in([:supporting_facts, :sent_id], [0, 99])

    feedback = %{context(:summarize2) | example: Imp.Example.new(malformed)}

    assert_raise ArgumentError, ~r/sentence index 99 is out of bounds/, fn ->
      HotpotFeedback.summarize2(feedback)
    end
  end

  test "fails closed without full program hop outputs" do
    prediction = Imp.Prediction.new(answer: "answer")
    feedback = %{context(:create_query_hop2) | program_output: prediction}

    assert_raise ArgumentError, ~r/missing required field :hop1_docs/, fn ->
      HotpotFeedback.create_query_hop2(feedback)
    end
  end

  test "fails closed when component-specific predictor inputs are missing" do
    feedback = %{context(:summarize2) | predictor_inputs: %{question: "Where?"}}

    assert_raise ArgumentError, ~r/missing required field :context/, fn ->
      HotpotFeedback.summarize2(feedback)
    end
  end

  defp context(component, opts \\ []) do
    answer = Keyword.get(opts, :answer, "The Answer")
    predicted_answer = Keyword.get(opts, :predicted_answer, "the answer")

    %ComponentFeedback{
      component: component,
      predictor_inputs: predictor_inputs(component),
      predictor_output: %{},
      example: Imp.Example.new(Map.put(example_fields(), :answer, answer)),
      program_output: program_output(predicted_answer, opts),
      trace: [],
      score: 1.0,
      metric_feedback: nil,
      metric_metadata: %{}
    }
  end

  defp program_output(predicted_answer, opts) do
    fields = %{
      answer: predicted_answer,
      hop1_docs: ["Bridge | retrieved first"],
      hop2_docs: ["Unrelated | noise"]
    }

    fields =
      case Keyword.fetch(opts, :output_feedback) do
        {:ok, output_feedback} -> Map.put(fields, :feedback_text, output_feedback)
        :error -> fields
      end

    Imp.Prediction.new(fields)
  end

  defp predictor_inputs(:create_query_hop2),
    do: %{question: "Where?", summary_1: "Bridge points onward."}

  defp predictor_inputs(:summarize2),
    do: %{question: "Where?", context: "Bridge points onward.", passages: ["passage"]}

  defp predictor_inputs(_component), do: %{}

  defp example_fields do
    %{
      question: "Where is the answer?",
      answer: "The Answer",
      supporting_facts: %{
        title: ["Bridge", "Destination"],
        sent_id: [0, 0]
      },
      context: %{
        title: ["Bridge", "Destination"],
        sentences: [["Bridge points onward."], ["Destination contains the answer."]]
      }
    }
  end

  defp stringify_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
