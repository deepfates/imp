defmodule CompletionSurfaceTest do
  use ExUnit.Case

  setup do
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "program of thought evaluates arithmetic in a safe sandbox" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2 + 1"} end]
    }

    program = DSEx.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ProgramOfThought.call(program, %{x: 3})
    assert DSEx.Prediction.get(prediction, :answer) == 7

    assert {:ok, "beam"} =
             DSEx.Sandbox.eval(
               "if String.contains?(text, \"BE\"), do: String.downcase(text), else: \"no\"",
               %{text: "BEAM"}
             )

    assert {:ok, true} = DSEx.Sandbox.eval("length([1, 2, 3]) == 3 and \"a\" in [\"a\", \"b\"]")
    assert {:ok, 5} = DSEx.Sandbox.eval("x + y", %{"x" => 2, y: 3})

    assert {:error, {:unsafe_ast, _}} =
             DSEx.Sandbox.eval("System.cmd(\"rm\", [\"-rf\", \"/\"])")

    external_identifier = "sandbox_external_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_identifier) end

    assert {:error, {:unknown_variable, ^external_identifier}} =
             DSEx.Sandbox.eval(external_identifier)

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_identifier) end
  end

  test "ProgramOfThought constructor rejects invalid option containers clearly" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.ProgramOfThought\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Predict.ProgramOfThought.new("x -> answer", %{lm: nil})
                 end
  end

  test "CodeAct loops through tool observations before evaluating a program" do
    actions = [
      %{tool: "lookup", arguments: %{"key" => "n"}},
      %{program: "observation + 1"}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_actions)
          Process.put(:code_act_actions, rest)
          action
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup a number", fn %{"key" => "n"} -> 41 end)
    Process.put(:code_act_actions, actions)

    code_act = DSEx.Predict.CodeAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = DSEx.Predict.CodeAct.call(code_act, %{question: "life?"})
    assert DSEx.Prediction.get(prediction, :answer) == 42
    assert Enum.map(prediction.metadata.code_act_trace, & &1.action) == [:tool, :program]
  after
    Process.delete(:code_act_actions)
  end

  test "CodeAct decodes JSON string tool arguments before execution" do
    actions = [
      %{tool: "lookup", arguments: ~s({"key":"n"})},
      %{program: "observation + 1"}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_actions)
          Process.put(:code_act_actions, rest)
          action
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup a number", fn %{"key" => "n"} -> 41 end)
    Process.put(:code_act_actions, actions)

    code_act = DSEx.Predict.CodeAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = DSEx.Predict.CodeAct.call(code_act, %{question: "life?"})
    assert DSEx.Prediction.get(prediction, :answer) == 42

    assert [
             %{action: :tool, input: %{arguments: %{"key" => "n"}}},
             %{action: :program}
           ] = prediction.metadata.code_act_trace
  after
    Process.delete(:code_act_actions)
  end

  test "CodeAct fails immediately on unknown denied or crashing tools with traces" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_failure_actions)
          Process.put(:code_act_failure_actions, rest)
          action
        end
      ]
    }

    Process.put(:code_act_failure_actions, [%{tool: "missing", arguments: %{}}])
    unknown = DSEx.Predict.CodeAct.new("question -> answer", [], lm: lm)

    assert {:error,
            {:code_act_tool_error, {:unknown_tool, "missing"},
             [%{action: :tool, output: {:error, {:unknown_tool, "missing"}}}]}} =
             DSEx.Predict.CodeAct.call(unknown, %{question: "q"})

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> "should not run" end)
    Process.put(:code_act_failure_actions, [%{tool: "lookup", arguments: %{}}])

    denied =
      DSEx.Predict.CodeAct.new("question -> answer", [lookup],
        lm: lm,
        tool_policy: [],
        max_iters: 2
      )

    assert {:error,
            {:code_act_tool_error, {:tool_denied, :lookup},
             [%{action: :tool, output: {:error, {:tool_denied, :lookup}}}]}} =
             DSEx.Predict.CodeAct.call(denied, %{question: "q"})

    boom = DSEx.Tool.new(:boom, "boom", fn _args -> raise "tool exploded" end)
    Process.put(:code_act_failure_actions, [%{tool: "boom", arguments: %{}}])
    crashing = DSEx.Predict.CodeAct.new("question -> answer", [boom], lm: lm, max_iters: 2)

    assert {:error,
            {:code_act_tool_error, {:tool_error, :boom, "tool exploded"},
             [%{action: :tool, output: {:error, {:tool_error, :boom, "tool exploded"}}}]}} =
             DSEx.Predict.CodeAct.call(crashing, %{question: "q"})
  after
    Process.delete(:code_act_failure_actions)
  end

  test "CodeAct sandbox rejection includes redacted trace context" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{program: "System.cmd(\"echo\", [])"}
        end
      ]
    }

    code_act = DSEx.Predict.CodeAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:code_act_sandbox_error, {:unsafe_ast, _ast}, [trace]}} =
             DSEx.Predict.CodeAct.call(code_act, %{question: "q"})

    assert %{
             action: :program,
             input: "System.cmd(\"echo\", [])",
             output: {:error, {:unsafe_ast, _}}
           } =
             trace
  end

  test "CodeAct non-positive max_iters fails before calling the planner" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :code_act_lm_called)
          %{program: "1 + 1"}
        end
      ]
    }

    code_act = DSEx.Predict.CodeAct.new("question -> answer", [], lm: lm, max_iters: -2)

    assert {:error, {:code_act_max_iters, 0, []}} =
             DSEx.Predict.CodeAct.call(code_act, %{question: "q"})

    refute_received :code_act_lm_called
  end

  test "CodeAct constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.CodeAct\.new\/3: expected keyword options/,
                 fn ->
                   DSEx.Predict.CodeAct.new("question -> answer", [], %{lm: nil})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.CodeAct\.new\/3 expects tools to be a list of DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.CodeAct.new("question -> answer", :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.CodeAct\.new\/3 expects tools to contain DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.CodeAct.new("question -> answer", [:not_a_tool])
                 end

    code_act = DSEx.Predict.CodeAct.new("question -> answer", [], lm: nil)

    assert {:error, {:invalid_code_act_inputs, message}} =
             DSEx.Predict.CodeAct.call(code_act, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_code_act_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.Predict.CodeAct.call(code_act, [:not_a_pair])
  end

  test "streaming exposes predictions as an enumerable" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.Streaming.collect(program, %{question: "runtime?"}) == "beam"

    assert Enum.take(DSEx.Streaming.stream(program, %{question: "runtime?"}), 2) == [
             "b",
             "e"
           ]

    assert [
             %{field: :answer, value: "beam"},
             %{field: :rationale, value: "fast"}
           ] =
             DSEx.Streaming.incremental_fields(
               ["[[ ## ans", "wer ## ]]beam", "[[ ## rationale ## ]]fast"],
               "question -> answer, rationale"
             )
  end

  test "streaming helpers validate owned options and provider-stream inputs" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    assert_raise ArgumentError, ~r/DSEx\.Streaming\.stream\/3: expected keyword options/, fn ->
      DSEx.Streaming.stream(program, %{question: "q"}, %{provider_stream: true}) |> Enum.to_list()
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Streaming\.stream\/3 expects :chunker to be nil or an arity-1 function/,
                 fn ->
                   DSEx.Streaming.stream(program, %{question: "q"}, chunker: :not_a_function)
                   |> Enum.to_list()
                 end

    assert [
             %DSEx.Streaming.Messages.StreamResponse{
               chunk: {:error, {:invalid_stream_inputs, "expected inputs as {key, value} pairs"}},
               done: true
             }
           ] =
             DSEx.Streaming.stream(program, [:not_a_pair], provider_stream: true)
             |> Enum.to_list()

    assert DSEx.Streaming.collect(program, %{question: "q"},
             provider_stream: true,
             temperature: 0
           ) ==
             "beam"
  end

  test "streaming fallback collects structured outputs in signature order" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{second: "two", first: "one"}
        end
      ]
    }

    program = DSEx.predict("question -> first, second", lm: lm)

    assert DSEx.Streaming.collect(program, %{question: "order?"}) == "onetwo"
    assert Enum.take(DSEx.Streaming.stream(program, %{question: "order?"}), 6) == ~w(o n e t w o)
  end

  test "dataset loaders produce examples with declared inputs" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-dataset-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":"3+3?","answer":"6"}\n))

    examples = DSEx.Datasets.gsm8k(path)
    assert length(examples) == 2
    assert DSEx.Example.to_map(DSEx.Example.inputs(hd(examples))) == %{question: "2+2?"}

    File.rm(path)
  end

  test "advanced optimizers return executable compiled programs" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.Example.with_inputs(:question),
      DSEx.example(question: "square root of 16?", answer: "4")
      |> DSEx.Example.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "2 plus 2?", answer: "4")
      |> DSEx.Example.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    compiled =
      [
        DSEx.Optimizer.COPRO.new(metric, breadth: 3, depth: 1),
        DSEx.Optimizer.MIPROv2.new(metric, trials: 3, demos_per_candidate: 1),
        DSEx.Optimizer.SIMBA.new(metric, steps: 2, demos_per_step: 1),
        DSEx.Optimizer.GEPA.new(metric, generations: 2),
        DSEx.Optimizer.SignatureOptimizer.new(metric)
      ]
      |> Enum.map(fn optimizer ->
        optimizer.__struct__.compile(optimizer, program, trainset, devset)
      end)

    assert Enum.all?(compiled, fn candidate ->
             {:ok, prediction} = DSEx.Predict.Predict.call(candidate, %{question: "2+2?"})
             DSEx.Prediction.get(prediction, :answer) == "4"
           end)
  end

  test "finetuning and GRPO require an explicit trainer backend" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = DSEx.predict("question -> answer", lm: lm)
    metric = DSEx.Metrics.exact_match(:answer)

    trainset = [
      DSEx.example(question: "2+2?", answer: "4") |> DSEx.Example.with_inputs(:question)
    ]

    result =
      DSEx.Optimizer.BootstrapFinetune.new(metric)
      |> DSEx.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %{program: %DSEx.Predict.Predict{}, error: :trainer_required} = result

    reward = fn example ->
      if DSEx.Example.get(example, :answer) == "4", do: 1.0, else: 0.0
    end

    assert {:error, :trainer_required} =
             DSEx.Optimizer.GRPO.new(reward)
             |> DSEx.Optimizer.GRPO.compile(program, trainset)
  end

  test "save/load, embeddings, and structured adapters work" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> ~s({"answer":"ok"}) end]
    }

    program = DSEx.predict("question -> answer", lm: lm, adapter: DSEx.Adapter.JSON)

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-program-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, prediction} = DSEx.Predict.Predict.call(program, %{question: "ship?"})
    assert DSEx.Prediction.get(prediction, :answer) == "ok"

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.Predict{} = DSEx.Saving.load!(path)
    File.rm(path)

    assert {:ok, [vector]} =
             DSEx.Embeddings.embed(DSEx.Embeddings.BagOfWords, ["hello hello beam"], dims: 8)

    assert length(vector) == 8

    messages = DSEx.Adapter.TwoStep.format(DSEx.signature("q -> a"), %{q: "x"}, [])
    assert Enum.any?(messages, &String.contains?(&1.content, "plan"))
  end
end
