defmodule DspyElixirTest do
  use ExUnit.Case

  setup do
    DSPy.configure(lm: nil, adapter: DSPy.Adapter.Chat, retriever: nil)
    :ok
  end

  test "parses DSPy-style signatures" do
    signature = DSPy.signature("question, context -> answer")

    assert DSPy.Signature.input_names(signature) == [:question, :context]
    assert DSPy.Signature.output_names(signature) == [:answer]
    assert DSPy.Signature.to_spec(signature) == "question, context -> answer"
  end

  test "examples split inputs and labels" do
    example =
      DSPy.example(question: "2+2?", answer: "4", dspy_internal: true)
      |> DSPy.Example.with_inputs(:question)

    assert DSPy.Example.to_map(DSPy.Example.inputs(example)) == %{question: "2+2?"}

    assert DSPy.Example.to_map(DSPy.Example.labels(example)) == %{
             answer: "4",
             dspy_internal: true
           }

    assert Enum.sort(DSPy.Example.keys(example)) == [:answer, :question]
  end

  test "predict formats through adapter and parses model output" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> "Answer: Paris" end]}
    program = DSPy.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DSPy.Predict.Predict.call(program, question: "Capital of France?")
    assert DSPy.Prediction.get(prediction, :answer) == "Paris"
    assert %{messages: [_system, _user], raw: "Answer: Paris"} = prediction.metadata.trace
  end

  test "chain of thought adds reasoning before answer" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{reasoning: "math", answer: "4"} end]
    }

    program = DSPy.chain_of_thought("question -> answer", lm: lm)

    assert {:ok, prediction} = DSPy.Predict.ChainOfThought.call(program, %{question: "2+2?"})
    assert DSPy.Prediction.get(prediction, :reasoning) == "math"
    assert DSPy.Prediction.get(prediction, :answer) == "4"
  end

  test "evaluate scores a program against examples" do
    lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSPy.predict("question -> answer", lm: lm)

    devset = [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question),
      DSPy.example(question: "3+3?", answer: "6") |> DSPy.Example.with_inputs(:question)
    ]

    result =
      devset |> DSPy.Evaluate.new(DSPy.Metrics.exact_match(:answer)) |> DSPy.Evaluate.run(program)

    assert result.score == 0.5
    assert length(result.rows) == 2
  end

  test "bootstrap few-shot selects successful demos" do
    handler = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "answer: 6", do: %{answer: "6"}, else: %{answer: "4"}
    end

    lm = %{module: DSPy.LM.Fake, opts: [handler: handler]}
    program = DSPy.predict("question -> answer", lm: lm)

    trainset = [
      DSPy.example(question: "2+2?", answer: "4") |> DSPy.Example.with_inputs(:question),
      DSPy.example(question: "3+3?", answer: "6") |> DSPy.Example.with_inputs(:question)
    ]

    optimizer =
      DSPy.Teleprompt.BootstrapFewShot.new(DSPy.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )

    compiled = DSPy.Teleprompt.BootstrapFewShot.compile(optimizer, program, trainset)

    assert length(compiled.demos) == 1
    assert DSPy.Example.get(hd(compiled.demos), :answer) == "4"
  end

  test "end-to-end retrieval augmented generation flow" do
    retriever =
      DSPy.Retrieve.Memory.new([
        %{id: 1, text: "Paris is the capital of France."},
        %{id: 2, text: "Berlin is the capital of Germany."}
      ])

    {:ok, docs} = DSPy.Retrieve.retrieve(retriever, "What is France's capital?", k: 1)
    context = docs |> hd() |> Map.fetch!(:text)

    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris", context: context} end]
    }

    program = DSPy.predict("question, context -> answer", lm: lm)

    example =
      DSPy.example(question: "What is France's capital?", context: context, answer: "Paris")
      |> DSPy.Example.with_inputs([:question, :context])

    evaluator = DSPy.Evaluate.new([example], DSPy.Metrics.exact_match(:answer))

    assert %{score: 1.0, rows: [%{error: nil}]} = DSPy.Evaluate.run(evaluator, program)
  end

  test "react can execute a requested tool" do
    tool = DSPy.Tool.new(:lookup, "Lookup a value", fn "x" -> "found x" end)

    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts -> %{tool: "lookup", tool_input: "x", answer: "pending"} end
      ]
    }

    program = DSPy.react("question -> answer", [tool], lm: lm)

    assert {:ok, prediction} = DSPy.Predict.ReAct.call(program, %{question: "Find x"})
    assert DSPy.Prediction.get(prediction, :observation) == "found x"
  end
end
