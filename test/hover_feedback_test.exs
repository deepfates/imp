defmodule DSEx.BenchmarkTruth.HoverFeedbackTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.{HoverFeedback, HoverMultiHop}
  alias DSEx.Optimizer.GEPA.ComponentFeedback

  test "exports the four source-named callbacks" do
    assert HoverFeedback.callbacks() |> Map.keys() |> Enum.sort() ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]
  end

  test "accepts only the complete source-shaped HoVer predictor graph" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _, _ -> %{} end]}
    program = HoverMultiHop.from_retriever(lm, fn _, _ -> {:ok, []} end)

    assert {:ok, callbacks} = HoverFeedback.callbacks_for(program)

    assert callbacks |> Map.keys() |> Enum.sort() ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]

    incompatible = DSEx.predict("claim -> answer", lm: lm)

    assert {:error, {:incompatible_predictors, %{missing: missing, unexpected: [:main]}}} =
             HoverFeedback.callbacks_for(incompatible)

    assert Enum.sort(missing) == Enum.sort(Map.keys(callbacks))
  end

  test "summary feedback credits evidence added after the selected summary" do
    result = HoverFeedback.summary(context(:summarize1, %{claim: "c", passages: hop1()}))

    refute result.feedback_score

    assert result.feedback_text =~
             "Successful retrieval:** Your summary correctly helped retrieve"

    assert result.feedback_text =~ "beta page"
    assert result.feedback_text =~ "Missing evidence:"
    assert result.feedback_text =~ "gamma page"
  end

  test "second summary uses cumulative hop-two evidence and accepts string keys" do
    context =
      context(:summarize2, %{
        "claim" => "c",
        "context" => "first summary",
        "passages" => hop2()
      })

    result = HoverFeedback.summary(context)

    refute result.feedback_score
    refute result.feedback_text =~ "Successful retrieval:"
    assert result.feedback_text =~ "gamma page"
  end

  test "query feedback distinguishes hop two and hop three" do
    hop2_result =
      HoverFeedback.query(context(:create_query_hop2, %{claim: "c", summary_1: "summary"}))

    assert hop2_result.feedback_text =~ "beta page"
    assert hop2_result.feedback_text =~ "gamma page"

    hop3_result =
      HoverFeedback.query(
        context(:create_query_hop3, %{
          claim: "c",
          summary_1: "one",
          summary_2: "two"
        })
      )

    refute hop3_result.feedback_text =~ "Successful retrieval:"
    assert hop3_result.feedback_text =~ "gamma page"
  end

  test "successful retrieval returns the upstream positive messages" do
    context = context(:create_query_hop3, %{summary_2: "two"}, include_gamma?: true)

    assert %{feedback_score: true, feedback_text: text} = HoverFeedback.query(context)

    assert text ==
             "Your queries are correct and useful in retrieving relevant evidence documents."

    assert %{feedback_score: true, feedback_text: text} =
             context
             |> Map.put(:component, :summarize2)
             |> Map.put(:predictor_inputs, %{context: "one"})
             |> HoverFeedback.summary()

    assert text ==
             "Your summaries are correct and useful in guiding query generation to retrieve relevant evidence documents."
  end

  test "fails closed when the two summary passage traces are unavailable" do
    context = %{context(:summarize1, %{passages: hop1()}) | trace: []}

    assert_raise ArgumentError, ~r/requires summarize1 and summarize2 trace inputs/, fn ->
      HoverFeedback.summary(context)
    end
  end

  defp context(component, predictor_inputs, opts \\ []) do
    final_docs =
      if Keyword.get(opts, :include_gamma?, false),
        do: hop1() ++ hop2() ++ ["Gamma Page | third"],
        else: hop1() ++ hop2()

    %ComponentFeedback{
      component: component,
      predictor_inputs: predictor_inputs,
      predictor_output: %{},
      example:
        DSEx.example(
          claim: "claim",
          supporting_facts: [
            %{"key" => "Beta Page"},
            %{key: "Gamma Page"}
          ]
        ),
      program_output: DSEx.prediction(retrieved_docs: final_docs),
      trace: [
        %{predictor: :summarize1, inputs: %{claim: "claim", passages: hop1()}, outputs: %{}},
        %{
          predictor: :summarize2,
          inputs: %{"claim" => "claim", "context" => "one", "passages" => hop2()},
          outputs: %{}
        }
      ],
      score: 0.0,
      metric_feedback: nil,
      metric_metadata: %{}
    }
  end

  defp hop1, do: ["Alpha Page | first"]
  defp hop2, do: ["Beta Page | second"]
end
