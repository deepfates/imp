defmodule Imp.BenchmarkTruth.HoverMultiHopTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.HoverMultiHop
  alias Imp.Module
  alias Imp.Optimizer.Trace
  alias Imp.Prediction

  test "executes the source three-hop graph with limits 7, 7, and 10" do
    owner = self()

    retriever = fn query, opts ->
      send(owner, {:retrieve, query, opts[:k]})
      {:ok, [%{title: "#{query} title", text: "evidence"}]}
    end

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          cond do
            prompt =~ "summary_2" -> %{reasoning: "third", query: "hop three"}
            prompt =~ "summary_1" -> %{reasoning: "second", query: "hop two"}
            prompt =~ "context" -> %{reasoning: "bridge", summary: "second summary"}
            true -> %{reasoning: "first", summary: "first summary"}
          end
        end
      )

    program = HoverMultiHop.from_retriever(lm, retriever)
    :ok = Trace.start()

    assert {:ok, prediction} = Module.call(program, %{claim: "original claim"})
    trace = Trace.finish()

    assert Prediction.get(prediction, :retrieved_docs) == [
             "original claim title | evidence",
             "hop two title | evidence",
             "hop three title | evidence"
           ]

    assert_receive {:retrieve, "original claim", 7}
    assert_receive {:retrieve, "hop two", 7}
    assert_receive {:retrieve, "hop three", 10}

    assert Enum.map(trace, & &1.predictor) == [
             :summarize1,
             :create_query_hop2,
             :summarize2,
             :create_query_hop3
           ]
  end

  test "exposes four independently optimizable ChainOfThought predictors" do
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{} end)
    program = HoverMultiHop.from_retriever(lm, fn _, _ -> {:ok, []} end)

    assert Enum.map(Imp.ProgramParameters.predictors(program), & &1.name) == [
             :summarize1,
             :create_query_hop2,
             :summarize2,
             :create_query_hop3
           ]

    updated = Imp.ProgramParameters.put_instruction(program, :create_query_hop3, "Bridge again.")
    assert updated.create_query_hop3.predict.signature.instructions == "Bridge again."
    refute updated.create_query_hop2.predict.signature.instructions == "Bridge again."
  end

  test "returns a structured stage error for malformed retrieval passages" do
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{} end)
    program = HoverMultiHop.from_retriever(lm, fn _, _ -> {:ok, [%{rank: 1}]} end)

    assert {:error, {:hover_multi_hop_failed, :hop1, {:invalid_hover_passage, %{rank: 1}}}} =
             Module.call(program, %{claim: "claim"})
  end
end
