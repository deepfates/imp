defmodule Imp.BenchmarkTruth.HoverFeedbackTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.{HoverFeedback, HoverMultiHop}
  alias Imp.Optimizer.GEPA.ComponentFeedback

  test "exports the four source-named callbacks" do
    assert HoverFeedback.callbacks() |> Map.keys() |> Enum.sort() ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]
  end

  test "accepts only the complete source-shaped HoVer predictor graph" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{} end]}
    program = HoverMultiHop.from_retriever(lm, fn _, _ -> {:ok, []} end)

    assert {:ok, callbacks} = HoverFeedback.callbacks_for(program)

    assert callbacks |> Map.keys() |> Enum.sort() ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]

    incompatible = Imp.predict("claim -> answer", lm: lm)

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

  test "public GEPA reflection reaches every named HoVer predictor" do
    owner = self()

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

          cond do
            prompt =~ "`summary`" -> %{reasoning: "evidence", summary: "alpha beta gamma"}
            prompt =~ "`query`" -> %{reasoning: "bridge", query: "gamma"}
          end
        end
      )

    retriever = fn _query, _opts ->
      {:ok,
       [
         %{title: "Alpha", text: "one"},
         %{title: "Beta", text: "two"},
         %{title: "Gamma", text: "three"}
       ]}
    end

    program = HoverMultiHop.from_retriever(task_lm, retriever)

    callbacks =
      HoverFeedback.callbacks()
      |> Map.new(fn {name, callback} ->
        {name,
         fn context ->
           send(owner, {:hover_feedback, name, context.component})
           callback.(context)
         end}
      end)

    proposer = fn candidate, _records, components ->
      send(owner, {:hover_reflection, components})

      %{new_texts: Map.new(components, &{&1, Map.fetch!(candidate, &1) <> " Improved."})}
    end

    example =
      Imp.example(claim: "Alpha connects to Gamma", supporting_facts: [%{key: "Gamma"}])
      |> Imp.with_inputs(:claim)

    {_selected, report} =
      Imp.Optimizer.GEPA.new(fn _example, _prediction -> 0.0 end,
        generations: 4,
        minibatch_size: 1,
        module_selector: :round_robin,
        reflection_strategy: proposer,
        component_feedback: callbacks
      )
      |> Imp.Optimizer.GEPA.compile_with_report(program, [example], [example])

    reflected =
      for _ <- 1..4 do
        assert_receive {:hover_reflection, [component]}
        component
      end

    assert reflected == [:summarize1, :create_query_hop2, :summarize2, :create_query_hop3]

    feedback =
      for _ <- 1..4 do
        assert_receive {:hover_feedback, component, component}
        component
      end

    assert Enum.sort(feedback) == Enum.sort(reflected)
    assert report.metadata.reflection_calls == 4
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
        Imp.example(
          claim: "claim",
          supporting_facts: [
            %{"key" => "Beta Page"},
            %{key: "Gamma Page"}
          ]
        ),
      program_output: Imp.prediction(retrieved_docs: final_docs),
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
