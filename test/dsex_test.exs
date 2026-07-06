defmodule DSExTest do
  use ExUnit.Case

  setup do
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "parses DSEx-style signatures" do
    signature = DSEx.signature("question, context -> answer")

    assert DSEx.Signature.input_names(signature) == [:question, :context]
    assert DSEx.Signature.output_names(signature) == [:answer]
    assert DSEx.Signature.to_spec(signature) == "question, context -> answer"
  end

  test "examples split inputs and labels" do
    example =
      DSEx.example(question: "2+2?", answer: "4", dsex_internal: true)
      |> DSEx.Example.with_inputs(:question)

    assert DSEx.Example.to_map(DSEx.Example.inputs(example)) == %{question: "2+2?"}

    assert DSEx.Example.to_map(DSEx.Example.labels(example)) == %{
             answer: "4",
             dsex_internal: true
           }

    assert Enum.sort(DSEx.Example.keys(example)) == [:answer, :question]
  end

  test "predict formats through adapter and parses model output" do
    lm = %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> "Answer: Paris" end]}
    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, question: "Capital of France?")

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert %{messages: [_system, _user], raw: "Answer: Paris"} = prediction.metadata.trace
  end

  test "chain of thought adds reasoning before answer" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{reasoning: "math", answer: "4"} end]
    }

    program = DSEx.chain_of_thought("question -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ChainOfThought.call(program, %{question: "2+2?"})
    assert DSEx.Prediction.get(prediction, :reasoning) == "math"
    assert DSEx.Prediction.get(prediction, :answer) == "4"
  end

  test "evaluate scores a program against examples" do
    lm = %{module: DSEx.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    devset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.Example.with_inputs(:question),
      DSEx.example(question: "3+3?", answer: "6") |> DSEx.Example.with_inputs(:question)
    ]

    result =
      devset
      |> DSEx.Evaluate.new(DSEx.Metrics.exact_match(:answer))
      |> DSEx.Evaluate.run(program)

    assert result.score == 0.5
    assert length(result.rows) == 2
  end

  test "bootstrap few-shot selects successful demos" do
    handler = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "answer: 6", do: %{answer: "6"}, else: %{answer: "4"}
    end

    lm = %{module: DSEx.LM.Fake, opts: [handler: handler]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.Example.with_inputs(:question),
      DSEx.example(question: "3+3?", answer: "6") |> DSEx.Example.with_inputs(:question)
    ]

    optimizer =
      DSEx.Optimizer.BootstrapFewShot.new(DSEx.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )

    compiled = DSEx.Optimizer.BootstrapFewShot.compile(optimizer, program, trainset)

    assert length(compiled.demos) == 1
    assert DSEx.Example.get(hd(compiled.demos), :answer) == "4"
  end

  test "end-to-end retrieval augmented generation flow" do
    retriever =
      DSEx.Retrieve.Memory.new([
        %{id: 1, text: "Paris is the capital of France."},
        %{id: 2, text: "Berlin is the capital of Germany."}
      ])

    {:ok, docs} = DSEx.Retrieve.retrieve(retriever, "What is France's capital?", k: 1)
    context = docs |> hd() |> Map.fetch!(:text)

    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris", context: context} end]
    }

    program = DSEx.predict("question, context -> answer", lm: lm)

    example =
      DSEx.example(question: "What is France's capital?", context: context, answer: "Paris")
      |> DSEx.Example.with_inputs([:question, :context])

    evaluator = DSEx.Evaluate.new([example], DSEx.Metrics.exact_match(:answer))

    assert %{score: 1.0, rows: [%{error: nil}]} = DSEx.Evaluate.run(evaluator, program)
  end

  test "react can execute a requested tool" do
    tool = DSEx.Tool.new(:lookup, "Lookup a value", fn "x" -> "found x" end)

    lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn _messages, _opts -> %{tool: "lookup", tool_input: "x", answer: "pending"} end
      ]
    }

    program = DSEx.react("question -> answer", [tool], lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(program, %{question: "Find x"})
    assert DSEx.Prediction.get(prediction, :observation) == "found x"
  end
end
