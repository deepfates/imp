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

  test "parses typed signatures with descriptions and constraints" do
    signature =
      DSEx.signature(
        ~s(question: string "User question", attempts: integer -> answer: string, confidence: number, verdict: enum[yes,no], extract: short_span)
      )

    assert [
             %{name: :question, type: :string, desc: "User question"},
             %{name: :attempts, type: :integer}
           ] =
             signature.inputs

    assert [
             %{name: :answer, type: :string},
             %{name: :confidence, type: :number},
             verdict,
             extract
           ] =
             signature.outputs

    assert verdict.type == :string
    assert verdict.metadata.constraints.enum == ["yes", "no"]
    assert extract.type == :string
    assert extract.metadata.constraints.answer_shape == :short_span

    assert {:ok, prediction} =
             DSEx.Adapter.Chat.parse(
               signature,
               %{answer: "ok", confidence: "0.8", verdict: "yes", extract: "Paris"},
               []
             )

    assert DSEx.Prediction.get(prediction, :confidence) == 0.8

    assert {:error, %DSEx.AdapterParseError{message: message}} =
             DSEx.Adapter.Chat.parse(
               signature,
               %{answer: "ok", confidence: "many", verdict: "maybe", extract: "Paris; France"},
               []
             )

    assert message =~ "confidence"
    assert message =~ "verdict"
    assert message =~ "extract"
  end

  test "builds signatures from decoded JSON-style string-key maps" do
    signature =
      DSEx.signature(%{
        "instructions" => "Answer carefully.",
        "metadata" => %{"source" => "json-config"},
        "inputs" => [%{"name" => "question", "type" => "string"}],
        "outputs" => [
          %{
            "name" => "answer",
            "type" => "string",
            "constraints" => %{"answerShape" => "short_span"}
          }
        ]
      })

    assert signature.instructions == "Answer carefully."
    assert signature.metadata == %{"source" => "json-config"}
    assert DSEx.Signature.input_names(signature) == [:question]
    assert DSEx.Signature.output_names(signature) == [:answer]
    assert hd(signature.outputs).metadata.constraints["answerShape"] == "short_span"
  end

  test "signature map constructor reports missing input output keys clearly" do
    assert_raise ArgumentError, ~r/requires :inputs\/:outputs/, fn ->
      DSEx.signature(%{"input" => ["question"], "output" => ["answer"]})
    end
  end

  test "signature parse errors include position and suggestions" do
    assert_raise DSEx.Signature.ParseError, ~r/position.*did you mean \"string\"/s, fn ->
      DSEx.signature("question: strng -> answer")
    end
  end

  test "configured settings resolve dynamically for existing programs" do
    first = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "first"} end]
    }

    second = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "second"} end]
    }

    DSEx.configure(lm: first)
    program = DSEx.predict("question -> answer")

    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "first"

    DSEx.configure(lm: second)
    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "second"
  end

  test "predict reports missing required inputs before calling the LM" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          flunk("LM should not be called when required inputs are missing")
        end
      ]
    }

    program = DSEx.predict("question, context -> answer", lm: lm)

    assert {:error, {:missing_input_fields, [:context]}} =
             DSEx.Predict.Predict.call(program, %{question: "q"})
  end

  test "predict accepts string-key inputs and allows optional inputs to be absent" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    signature =
      DSEx.Signature.new(%{
        inputs: [
          %{name: :question, type: :string},
          %{name: :context, type: :string, metadata: %{optional: true}}
        ],
        outputs: [:answer]
      })

    program = DSEx.predict(signature, lm: lm)

    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{"question" => "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "ok"
  end

  test "context settings are process-local and restored" do
    global = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "global"} end]
    }

    local = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "local"} end]
    }

    DSEx.configure(lm: global)
    program = DSEx.predict("question -> answer")

    inside =
      DSEx.context([lm: local], fn ->
        task = Task.async(fn -> DSEx.call(program, %{question: "q"}) end)

        {:ok, local_prediction} = DSEx.call(program, %{question: "q"})
        {:ok, task_prediction} = Task.await(task)

        {DSEx.get(local_prediction, :answer), DSEx.get(task_prediction, :answer)}
      end)

    assert inside == {"local", "global"}
    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "global"
  end

  test "DSEx-owned task fan-out inherits context settings" do
    global = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "global"} end]
    }

    local = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "local"} end]
    }

    DSEx.configure(lm: global)
    program = DSEx.predict("question -> answer")

    results =
      DSEx.context([lm: local], fn ->
        DSEx.Predict.Parallel.map(program, [%{question: "a"}, %{question: "b"}],
          max_concurrency: 2
        )
      end)

    assert [{:ok, first}, {:ok, second}] = results
    assert DSEx.get(first, :answer) == "local"
    assert DSEx.get(second, :answer) == "local"
  end

  test "RLM controller LM resolves settings dynamically" do
    first = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "first"}} end]
    }

    second = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{action: "submit", result: %{answer: "second"}} end]
    }

    DSEx.configure(lm: first)
    rlm = DSEx.rlm("question -> answer")

    assert {:ok, prediction} = DSEx.call(rlm, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "first"

    DSEx.configure(lm: second)
    assert {:ok, prediction} = DSEx.call(rlm, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "second"
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
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> "Answer: Paris" end]}
    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             DSEx.Predict.Predict.call(program, question: "Capital of France?")

    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert %{messages: [_system, _user], raw: "Answer: Paris"} = prediction.metadata.trace
  end

  test "chain of thought adds reasoning before answer" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{reasoning: "math", answer: "4"} end]
    }

    program = DSEx.chain_of_thought("question -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ChainOfThought.call(program, %{question: "2+2?"})
    assert DSEx.Prediction.get(prediction, :reasoning) == "math"
    assert DSEx.Prediction.get(prediction, :answer) == "4"
  end

  test "KNN predictor uses configured query fields instead of all inputs" do
    trainset = [
      DSEx.example(question: "capital france", answer: "Paris") |> DSEx.with_inputs(:question),
      DSEx.example(question: "color sky", answer: "blue") |> DSEx.with_inputs(:question)
    ]

    knn = DSEx.Predict.KNN.new(1, trainset, field: :question)

    assert [%DSEx.Example{} = nearest] =
             DSEx.Predict.KNN.call(knn, %{
               "question" => "capital",
               distractor: "sky sky sky"
             })

    assert DSEx.Example.get(nearest, :answer) == "Paris"
  end

  test "KNN predictor can query from multiple fields" do
    trainset = [
      DSEx.example(subject: "paris", detail: "france", answer: "capital")
      |> DSEx.with_inputs([:subject, :detail]),
      DSEx.example(subject: "beam", detail: "concurrency", answer: "otp")
      |> DSEx.with_inputs([:subject, :detail])
    ]

    knn = DSEx.Predict.KNN.new(1, trainset, field: [:subject, :detail])

    assert [%DSEx.Example{} = nearest] =
             DSEx.Predict.KNN.call(knn, %{subject: "beam", detail: "process concurrency"})

    assert DSEx.Example.get(nearest, :answer) == "otp"
  end

  test "evaluate scores a program against examples" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
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
      if prompt =~ "[[ ## answer ## ]]\n6", do: %{answer: "6"}, else: %{answer: "4"}
    end

    lm = %{module: DSEx.LM.Static, opts: [handler: handler]}
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
      module: DSEx.LM.Static,
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
    tool = DSEx.Tool.new(:lookup, "Lookup a value", fn %{query: "x"} -> "found x" end)

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{name: :lookup, arguments: %{query: "x"}},
              %{name: :submit, arguments: %{answer: "found x"}}
            ]
          }
        end
      ]
    }

    program = DSEx.react("question -> answer", [tool], lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(program, %{question: "Find x"})
    assert DSEx.Prediction.get(prediction, :answer) == "found x"
    assert [%{tool: :lookup}, %{tool: :submit}] = DSEx.Prediction.get(prediction, :history)
  end
end
