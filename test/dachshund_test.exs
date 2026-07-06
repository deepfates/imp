defmodule DachshundTest do
  use ExUnit.Case

  setup do
    Dachshund.configure(lm: nil, adapter: Dachshund.Adapter.Chat, retriever: nil)
    :ok
  end

  test "parses Dachshund-style signatures" do
    signature = Dachshund.signature("question, context -> answer")

    assert Dachshund.Signature.input_names(signature) == [:question, :context]
    assert Dachshund.Signature.output_names(signature) == [:answer]
    assert Dachshund.Signature.to_spec(signature) == "question, context -> answer"
  end

  test "examples split inputs and labels" do
    example =
      Dachshund.example(question: "2+2?", answer: "4", dachshund_internal: true)
      |> Dachshund.Example.with_inputs(:question)

    assert Dachshund.Example.to_map(Dachshund.Example.inputs(example)) == %{question: "2+2?"}

    assert Dachshund.Example.to_map(Dachshund.Example.labels(example)) == %{
             answer: "4",
             dachshund_internal: true
           }

    assert Enum.sort(Dachshund.Example.keys(example)) == [:answer, :question]
  end

  test "predict formats through adapter and parses model output" do
    lm = %{module: Dachshund.LM.Fake, opts: [handler: fn _messages, _opts -> "Answer: Paris" end]}
    program = Dachshund.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             Dachshund.Predict.Predict.call(program, question: "Capital of France?")

    assert Dachshund.Prediction.get(prediction, :answer) == "Paris"
    assert %{messages: [_system, _user], raw: "Answer: Paris"} = prediction.metadata.trace
  end

  test "chain of thought adds reasoning before answer" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{reasoning: "math", answer: "4"} end]
    }

    program = Dachshund.chain_of_thought("question -> answer", lm: lm)

    assert {:ok, prediction} = Dachshund.Predict.ChainOfThought.call(program, %{question: "2+2?"})
    assert Dachshund.Prediction.get(prediction, :reasoning) == "math"
    assert Dachshund.Prediction.get(prediction, :answer) == "4"
  end

  test "evaluate scores a program against examples" do
    lm = %{module: Dachshund.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Dachshund.predict("question -> answer", lm: lm)

    devset = [
      Dachshund.example(question: "2+2?", answer: "4")
      |> Dachshund.Example.with_inputs(:question),
      Dachshund.example(question: "3+3?", answer: "6") |> Dachshund.Example.with_inputs(:question)
    ]

    result =
      devset
      |> Dachshund.Evaluate.new(Dachshund.Metrics.exact_match(:answer))
      |> Dachshund.Evaluate.run(program)

    assert result.score == 0.5
    assert length(result.rows) == 2
  end

  test "bootstrap few-shot selects successful demos" do
    handler = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "answer: 6", do: %{answer: "6"}, else: %{answer: "4"}
    end

    lm = %{module: Dachshund.LM.Fake, opts: [handler: handler]}
    program = Dachshund.predict("question -> answer", lm: lm)

    trainset = [
      Dachshund.example(question: "2+2?", answer: "4")
      |> Dachshund.Example.with_inputs(:question),
      Dachshund.example(question: "3+3?", answer: "6") |> Dachshund.Example.with_inputs(:question)
    ]

    optimizer =
      Dachshund.Optimizer.BootstrapFewShot.new(Dachshund.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )

    compiled = Dachshund.Optimizer.BootstrapFewShot.compile(optimizer, program, trainset)

    assert length(compiled.demos) == 1
    assert Dachshund.Example.get(hd(compiled.demos), :answer) == "4"
  end

  test "end-to-end retrieval augmented generation flow" do
    retriever =
      Dachshund.Retrieve.Memory.new([
        %{id: 1, text: "Paris is the capital of France."},
        %{id: 2, text: "Berlin is the capital of Germany."}
      ])

    {:ok, docs} = Dachshund.Retrieve.retrieve(retriever, "What is France's capital?", k: 1)
    context = docs |> hd() |> Map.fetch!(:text)

    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris", context: context} end]
    }

    program = Dachshund.predict("question, context -> answer", lm: lm)

    example =
      Dachshund.example(question: "What is France's capital?", context: context, answer: "Paris")
      |> Dachshund.Example.with_inputs([:question, :context])

    evaluator = Dachshund.Evaluate.new([example], Dachshund.Metrics.exact_match(:answer))

    assert %{score: 1.0, rows: [%{error: nil}]} = Dachshund.Evaluate.run(evaluator, program)
  end

  test "react can execute a requested tool" do
    tool = Dachshund.Tool.new(:lookup, "Lookup a value", fn "x" -> "found x" end)

    lm = %{
      module: Dachshund.LM.Fake,
      opts: [
        handler: fn _messages, _opts -> %{tool: "lookup", tool_input: "x", answer: "pending"} end
      ]
    }

    program = Dachshund.react("question -> answer", [tool], lm: lm)

    assert {:ok, prediction} = Dachshund.Predict.ReAct.call(program, %{question: "Find x"})
    assert Dachshund.Prediction.get(prediction, :observation) == "found x"
  end
end
