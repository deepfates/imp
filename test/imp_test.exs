defmodule ImpTest do
  use ExUnit.Case

  setup do
    Imp.configure(lm: nil, adapter: Imp.Adapter.Chat, retriever: nil)
    # Restore the global Imp.Settings Agent to defaults after every test so a
    # non-default :lm (set by tests here) cannot leak into a later module's
    # BootstrapFewShot demo capture. See dee-fqsr (order-dependent digest flake).
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "parses Imp-style signatures" do
    signature = Imp.signature("question, context -> answer")

    assert Imp.Signature.input_names(signature) == [:question, :context]
    assert Imp.Signature.output_names(signature) == [:answer]
    assert Imp.Signature.to_spec(signature) == "question, context -> answer"
  end

  test "parses typed signatures with descriptions and constraints" do
    signature =
      Imp.signature(
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
             Imp.Adapter.Chat.parse(
               signature,
               %{answer: "ok", confidence: "0.8", verdict: "yes", extract: "Paris"},
               []
             )

    assert Imp.Prediction.get(prediction, :confidence) == 0.8

    assert {:error, %Imp.AdapterParseError{message: message}} =
             Imp.Adapter.Chat.parse(
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
      Imp.signature(%{
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
    assert Imp.Signature.input_names(signature) == [:question]
    assert Imp.Signature.output_names(signature) == [:answer]
    assert hd(signature.outputs).metadata.constraints["answerShape"] == "short_span"
  end

  test "signature map constructor reports missing input output keys clearly" do
    assert_raise ArgumentError, ~r/requires :inputs\/:outputs/, fn ->
      Imp.signature(%{"input" => ["question"], "output" => ["answer"]})
    end
  end

  test "signature constructors report malformed structured fields clearly" do
    assert_raise ArgumentError,
                 ~r/Imp.Signature.new\/2 :inputs expects an enumerable of fields/,
                 fn ->
                   Imp.Signature.new(%{inputs: :question, outputs: [:answer]})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Signature.new\/2 :outputs: Imp.Signature.Field.new\/2 expects field name/,
                 fn ->
                   Imp.Signature.new(%{inputs: [:question], outputs: [1]})
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Signature.new\/2 :outputs: Imp.Signature.Field.new\/2 expects field type/,
                 fn ->
                   Imp.Signature.new(%{
                     inputs: [:question],
                     outputs: [%{name: :answer, type: 123}]
                   })
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Signature.extend\/3 expects kind to be :input or :output/,
                 fn ->
                   Imp.Signature.extend(Imp.signature("question -> answer"), :context, :middle)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Signature.load\/1 expects a map with "inputs" and "outputs"/,
                 fn ->
                   Imp.Signature.load(%{"input" => []})
                 end
  end

  test "examples and predictions report invalid field containers clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Example\.new\/1 expects a map, field pair list, or Imp\.Example/,
                 fn ->
                   Imp.Example.new(:not_fields)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Prediction\.new\/2 expects a map or field pair list/,
                 fn ->
                   Imp.Prediction.new(:not_fields)
                 end
  end

  test "examples and predictions report malformed field pair lists clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Example\.new\/1 expects fields as \{key, value\} pairs/,
                 fn ->
                   Imp.Example.new([:not_a_pair])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Prediction\.new\/2 expects fields as \{key, value\} pairs/,
                 fn ->
                   Imp.Prediction.new([:not_a_pair])
                 end
  end

  test "prediction reports invalid options clearly" do
    assert_raise ArgumentError, ~r/Imp\.Prediction\.new\/2: expected keyword options/, fn ->
      Imp.Prediction.new(%{answer: "4"}, :not_options)
    end

    assert_raise ArgumentError, ~r/Imp\.Prediction\.new\/2.*:metadata.*expected.*map/s, fn ->
      Imp.Prediction.new(%{answer: "4"}, metadata: :not_metadata)
    end
  end

  test "examples and predictions reject non atom or string keys clearly" do
    assert_raise ArgumentError, ~r/Imp\.Example keys must be atoms or strings/, fn ->
      Imp.Example.new(%{1 => "bad"})
    end

    assert_raise ArgumentError, ~r/Imp\.Prediction keys must be atoms or strings/, fn ->
      Imp.Prediction.new(%{1 => "bad"})
    end

    example = Imp.example(question: "2+2?", answer: "4")
    prediction = Imp.prediction(answer: "4")

    assert_raise ArgumentError, ~r/Imp\.Example keys must be atoms or strings/, fn ->
      Imp.Example.get(example, 1)
    end

    assert_raise ArgumentError, ~r/Imp\.Prediction keys must be atoms or strings/, fn ->
      Imp.Prediction.get(prediction, 1)
    end
  end

  test "signature parse errors include position and suggestions" do
    assert_raise Imp.Signature.ParseError, ~r/position.*did you mean \"string\"/s, fn ->
      Imp.signature("question: strng -> answer")
    end
  end

  test "signature parse error suggests array[...] for DSPy's list[...] form" do
    error =
      assert_raise Imp.Signature.ParseError, fn ->
        Imp.signature("question -> tags: list[string]")
      end

    assert error.message =~
             ~s{did you mean "array[string]"? (Imp uses array[...] where DSPy uses list[...])}

    # DSPy's Python capitalization is handled too.
    upper =
      assert_raise Imp.Signature.ParseError, fn ->
        Imp.signature("question -> tags: List[string]")
      end

    assert upper.message =~ ~s{did you mean "array[string]"?}

    # Bare list -> array.
    bare =
      assert_raise Imp.Signature.ParseError, fn ->
        Imp.signature("question -> tags: list")
      end

    assert bare.message =~ ~s{did you mean "array"?}

    # Genuinely unknown scalars still suggest the nearest scalar type.
    scalar =
      assert_raise Imp.Signature.ParseError, fn ->
        Imp.signature("question: strng -> answer")
      end

    assert scalar.message =~ ~s{did you mean "string"?}
    refute scalar.message =~ "array"
  end

  test "configured settings resolve dynamically for existing programs" do
    first = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "first"} end]
    }

    second = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "second"} end]
    }

    Imp.configure(lm: first)
    program = Imp.predict("question -> answer")

    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "first"

    Imp.configure(lm: second)
    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "second"
  end

  test "predict reports missing required inputs before calling the LM" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          flunk("LM should not be called when required inputs are missing")
        end
      ]
    }

    program = Imp.predict("question, context -> answer", lm: lm)

    assert {:error, {:missing_input_fields, [:context]}} =
             Imp.Predict.Predict.call(program, %{question: "q"})
  end

  test "predict constructor and call report invalid inputs clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: expected keyword options/,
                 fn ->
                   Imp.predict("question -> answer", :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2.*:config.*expected.*keyword/s,
                 fn ->
                   Imp.predict("question -> answer", config: :not_config)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2.*:metadata.*expected.*map/s,
                 fn ->
                   Imp.predict("question -> answer", metadata: :not_metadata)
                 end

    program = Imp.predict("question -> answer", lm: %{module: Imp.LM.Static, opts: []})

    assert {:error, {:invalid_predict_inputs, message}} =
             Imp.Predict.Predict.call(program, :not_inputs)

    assert message =~ "expected a map or field pair list"

    assert {:error, {:invalid_predict_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.Predict.Predict.call(program, [:not_a_pair])
  end

  test "predict normalizes constructor demos into examples" do
    program =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: []},
        demos: [question: "2+2?", answer: "4"]
      )

    assert [%Imp.Example{} = demo] = program.demos
    assert Imp.Example.to_map(demo) == %{question: "2+2?", answer: "4"}

    assert_raise ArgumentError,
                 ~r/Imp.Predict.Predict.new\/2 expects demos as Imp.Example structs/,
                 fn ->
                   Imp.predict("question -> answer",
                     lm: %{module: Imp.LM.Static, opts: []},
                     demos: [:not_a_demo]
                   )
                 end
  end

  test "predict accepts string-key inputs and allows optional inputs to be absent" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    signature =
      Imp.Signature.new(%{
        inputs: [
          %{name: :question, type: :string},
          %{name: :context, type: :string, metadata: %{optional: true}}
        ],
        outputs: [:answer]
      })

    program = Imp.predict(signature, lm: lm)

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{"question" => "q"})
    assert Imp.Prediction.get(prediction, :answer) == "ok"
  end

  test "context settings are process-local and restored" do
    global = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "global"} end]
    }

    local = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "local"} end]
    }

    Imp.configure(lm: global)
    program = Imp.predict("question -> answer")

    inside =
      Imp.context([lm: local], fn ->
        task = Task.async(fn -> Imp.call(program, %{question: "q"}) end)

        {:ok, local_prediction} = Imp.call(program, %{question: "q"})
        {:ok, task_prediction} = Task.await(task)

        {Imp.get(local_prediction, :answer), Imp.get(task_prediction, :answer)}
      end)

    assert inside == {"local", "global"}
    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "global"
  end

  test "Imp-owned task fan-out inherits context settings" do
    global = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "global"} end]
    }

    local = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "local"} end]
    }

    Imp.configure(lm: global)
    program = Imp.predict("question -> answer")

    results =
      Imp.context([lm: local], fn ->
        Imp.Predict.Parallel.map(program, [%{question: "a"}, %{question: "b"}],
          max_concurrency: 2
        )
      end)

    assert [{:ok, first}, {:ok, second}] = results
    assert Imp.get(first, :answer) == "local"
    assert Imp.get(second, :answer) == "local"
  end

  test "RLM controller LM resolves settings dynamically" do
    first = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{code: ~S|submit(%{answer: "first"})|} end]
    }

    second = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{code: ~S|submit(%{answer: "second"})|} end]
    }

    Imp.configure(lm: first)
    rlm = Imp.rlm("question -> answer")

    assert {:ok, prediction} = Imp.call(rlm, %{question: "q"})
    assert Imp.get(prediction, :answer) == "first"

    Imp.configure(lm: second)
    assert {:ok, prediction} = Imp.call(rlm, %{question: "q"})
    assert Imp.get(prediction, :answer) == "second"
  end

  test "examples split inputs and labels" do
    example =
      Imp.example(question: "2+2?", answer: "4", imp_internal: true)
      |> Imp.Example.with_inputs(:question)

    assert Imp.Example.to_map(Imp.Example.inputs(example)) == %{question: "2+2?"}

    assert Imp.Example.to_map(Imp.Example.labels(example)) == %{
             answer: "4",
             imp_internal: true
           }

    assert Enum.sort(Imp.Example.keys(example)) == [:answer, :question]
  end

  test "predict formats through adapter and parses model output" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> "Answer: Paris" end]}
    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, prediction} =
             Imp.Predict.Predict.call(program, question: "Capital of France?")

    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert %{messages: [_system, _user], raw: "Answer: Paris"} = prediction.metadata.trace
  end

  test "chain of thought adds reasoning before answer" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{reasoning: "math", answer: "4"} end]
    }

    program = Imp.chain_of_thought("question -> answer", lm: lm)

    assert {:ok, prediction} = Imp.Predict.ChainOfThought.call(program, %{question: "2+2?"})
    assert Imp.Prediction.get(prediction, :reasoning) == "math"
    assert Imp.Prediction.get(prediction, :answer) == "4"
  end

  test "KNN predictor uses configured query fields instead of all inputs" do
    trainset = [
      Imp.example(question: "capital france", answer: "Paris") |> Imp.with_inputs(:question),
      Imp.example(question: "color sky", answer: "blue") |> Imp.with_inputs(:question)
    ]

    knn = Imp.Predict.KNN.new(1, trainset, field: :question)

    assert [%Imp.Example{} = nearest] =
             Imp.Predict.KNN.call(knn, %{
               "question" => "capital",
               distractor: "sky sky sky"
             })

    assert Imp.Example.get(nearest, :answer) == "Paris"
  end

  test "KNN predictor can query from multiple fields" do
    trainset = [
      Imp.example(subject: "paris", detail: "france", answer: "capital")
      |> Imp.with_inputs([:subject, :detail]),
      Imp.example(subject: "beam", detail: "concurrency", answer: "otp")
      |> Imp.with_inputs([:subject, :detail])
    ]

    knn = Imp.Predict.KNN.new(1, trainset, field: [:subject, :detail])

    assert [%Imp.Example{} = nearest] =
             Imp.Predict.KNN.call(knn, %{subject: "beam", detail: "process concurrency"})

    assert Imp.Example.get(nearest, :answer) == "otp"
  end

  test "KNN predictor reports invalid constructor and call inputs clearly" do
    assert_raise ArgumentError, ~r/Imp\.Predict\.KNN\.new\/3: expected keyword options/, fn ->
      Imp.Predict.KNN.new(1, [], %{field: :question})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.KNN\.new\/3: invalid value for :field option: expected an atom\/string field name or a non-empty list of field names/,
                 fn ->
                   Imp.Predict.KNN.new(1, [], field: nil)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Retrievers\.KNN\.new\/2 expects examples to be an enumerable/,
                 fn ->
                   Imp.Predict.KNN.new(1, :not_trainset)
                 end

    knn = Imp.Predict.KNN.new(1, [])

    assert_raise ArgumentError, ~r/Imp\.Predict\.KNN\.call\/2 expects inputs as a map/, fn ->
      Imp.Predict.KNN.call(knn, :not_inputs)
    end

    assert_raise ArgumentError, ~r/Imp\.Predict\.KNN\.call\/2 expects inputs as a map/, fn ->
      Imp.Predict.KNN.call(knn, [:not_a_pair])
    end
  end

  test "evaluate scores a program against examples" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Imp.predict("question -> answer", lm: lm)

    devset = [
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.Example.with_inputs(:question),
      Imp.example(question: "3+3?", answer: "6") |> Imp.Example.with_inputs(:question)
    ]

    result =
      devset
      |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer))
      |> Imp.Evaluate.run(program)

    assert result.score == 0.5
    assert length(result.rows) == 2
  end

  test "parallel evaluate records timed-out rows without exiting the caller" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> Process.sleep(:infinity) end]
    }

    program = Imp.predict("question -> answer", lm: lm)

    devset =
      Enum.map(1..2, fn index ->
        Imp.example(question: "blocked #{index}", answer: "never")
        |> Imp.Example.with_inputs(:question)
      end)

    result =
      devset
      |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer),
        max_concurrency: 2,
        max_errors: :infinity,
        timeout: 10
      )
      |> Imp.Evaluate.run(program)

    assert result.score == 0.0
    assert length(result.rows) == 2
    assert Enum.all?(result.errors, &match?(%{reason: {:evaluation_task_exit, :timeout}}, &1))
  end

  test "evaluate and optimizers apply no per-row timeout by default" do
    # Regression (discovered 2026-07-16): the old 5s default silently scored
    # slow-but-correct live model calls as failure_score 0.0 inside optimizer
    # candidate search, corrupting selection with no loud signal.
    metric = Imp.Metrics.exact_match(:answer)
    devset = [Imp.example(question: "2+2?", answer: "4") |> Imp.Example.with_inputs(:question)]

    assert Imp.Evaluate.new(devset, metric).timeout == :infinity
    assert Imp.Optimizer.MIPROv2.new(metric).timeout == :infinity
    assert Imp.Optimizer.SIMBA.new(metric).timeout == :infinity
  end

  test "a timed-out row is loud and distinguishable from a wrong answer" do
    handler = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "slow", do: Process.sleep(:infinity), else: %{answer: "wrong"}
    end

    lm = %{module: Imp.LM.Static, opts: [handler: handler]}
    program = Imp.predict("question -> answer", lm: lm)

    devset = [
      Imp.example(question: "slow question", answer: "right")
      |> Imp.Example.with_inputs(:question),
      Imp.example(question: "fast question", answer: "right")
      |> Imp.Example.with_inputs(:question)
    ]

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        devset
        |> Imp.Evaluate.new(Imp.Metrics.exact_match(:answer),
          max_concurrency: 2,
          max_errors: :infinity,
          timeout: 100
        )
        |> Imp.Evaluate.run(program)
      end)

    [timed_out, wrong] = result.rows

    assert timed_out.error == {:evaluation_task_exit, :timeout}
    assert timed_out.prediction == nil

    assert wrong.error == nil
    refute wrong.prediction == nil
    refute wrong.passed?

    assert [%{index: 0, reason: {:evaluation_task_exit, :timeout}}] = result.errors
    assert log =~ "killed row 0"
    assert log =~ "not a model miss"
  end

  test "bootstrap few-shot selects successful demos" do
    handler = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "[[ ## answer ## ]]\n6", do: %{answer: "6"}, else: %{answer: "4"}
    end

    lm = %{module: Imp.LM.Static, opts: [handler: handler]}
    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.Example.with_inputs(:question),
      Imp.example(question: "3+3?", answer: "6") |> Imp.Example.with_inputs(:question)
    ]

    optimizer =
      Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    compiled = Imp.Optimizer.BootstrapFewShot.compile(optimizer, program, trainset)

    assert length(compiled.demos) == 1
    assert Imp.Example.get(hd(compiled.demos), :answer) == "4"
  end

  test "end-to-end retrieval augmented generation flow" do
    retriever =
      Imp.Retrieve.Memory.new([
        %{id: 1, text: "Paris is the capital of France."},
        %{id: 2, text: "Berlin is the capital of Germany."}
      ])

    {:ok, docs} = Imp.Retrieve.retrieve(retriever, "What is France's capital?", k: 1)
    context = docs |> hd() |> Map.fetch!(:text)

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris", context: context} end]
    }

    program = Imp.predict("question, context -> answer", lm: lm)

    example =
      Imp.example(question: "What is France's capital?", context: context, answer: "Paris")
      |> Imp.Example.with_inputs([:question, :context])

    evaluator = Imp.Evaluate.new([example], Imp.Metrics.exact_match(:answer))

    assert %{score: 1.0, rows: [%{error: nil}]} = Imp.Evaluate.run(evaluator, program)
  end

  test "react can execute a requested tool" do
    tool = Imp.Tool.new(:lookup, "Lookup a value", fn %{query: "x"} -> "found x" end)

    lm = %{
      module: Imp.LM.Static,
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

    program = Imp.react("question -> answer", [tool], lm: lm)

    assert {:ok, prediction} = Imp.Predict.ReAct.call(program, %{question: "Find x"})
    assert Imp.Prediction.get(prediction, :answer) == "found x"
    assert [%{tool: :lookup}, %{tool: :submit}] = Imp.Prediction.get(prediction, :history)
  end
end
