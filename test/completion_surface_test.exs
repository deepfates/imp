defmodule CompletionSurfaceTest do
  use ExUnit.Case

  defmodule RaisingEmbedder do
    @behaviour Imp.Embeddings

    def embed(_texts, _opts), do: raise("embed exploded")
  end

  defmodule StreamingRaisingAdapter do
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: raise("streaming format exploded")
    def parse(_signature, _raw, _opts), do: {:ok, Imp.prediction(answer: "unused")}
  end

  defmodule StreamingInvalidLMOptsAdapter do
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]
    def parse(_signature, _raw, _opts), do: {:ok, Imp.prediction(answer: "unused")}
    def lm_opts(_signature, _opts), do: %{response_format: %{type: "json_object"}}
  end

  defmodule StreamingLMOptsAdapter do
    @behaviour Imp.Adapter

    def format(_signature, _inputs, _opts), do: [%{role: :user, content: "q"}]
    def parse(_signature, _raw, _opts), do: {:ok, Imp.prediction(answer: "unused")}
    def lm_opts(_signature, _opts), do: [marker: :from_adapter]
  end

  setup do
    Imp.configure(lm: nil, adapter: Imp.Adapter.Chat, retriever: nil)
    # Restore global Imp.Settings to defaults on exit so this module never
    # leaves non-default settings for a later module. See dee-fqsr.
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "program of thought evaluates arithmetic in a safe sandbox" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2 + 1"} end]
    }

    program = Imp.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:ok, prediction} = Imp.Predict.ProgramOfThought.call(program, %{x: 3})
    assert Imp.Prediction.get(prediction, :answer) == 7

    assert {:ok, "beam"} =
             Imp.Sandbox.eval(
               "if String.contains?(text, \"BE\"), do: String.downcase(text), else: \"no\"",
               %{text: "BEAM"}
             )

    assert {:ok, true} = Imp.Sandbox.eval("length([1, 2, 3]) == 3 and \"a\" in [\"a\", \"b\"]")
    assert {:ok, 5} = Imp.Sandbox.eval("x + y", %{"x" => 2, y: 3})

    assert {:ok, 7} =
             Imp.Sandbox.eval("if enabled do\n  7\nelse\n  0\nend", %{"enabled" => true})

    map_key = "sandbox_map_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(map_key) end

    assert {:ok, %{"answer" => 7, ^map_key => %{"items" => [3, 4]}}} =
             Imp.Sandbox.eval(
               ~s(%{"#{map_key}" => %{items: [x, x + 1]}, answer: x * 2 + 1}),
               %{"x" => 3}
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(map_key) end

    assert {:error, {:unsafe_ast, _}} =
             Imp.Sandbox.eval("%{existing | answer: 7}", %{existing: %{}})

    assert {:error, {:unsafe_ast, _}} =
             Imp.Sandbox.eval("System.cmd(\"rm\", [\"-rf\", \"/\"])")

    external_identifier = "sandbox_external_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(external_identifier) end

    assert {:error, {:unknown_variable, ^external_identifier}} =
             Imp.Sandbox.eval(external_identifier)

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_identifier) end
  end

  test "ProgramOfThought constructor rejects invalid option containers clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ProgramOfThought\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Predict.ProgramOfThought.new("x -> answer", %{lm: nil})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ProgramOfThought\.new\/2: invalid value for :output_field option: expected an atom\/string field name/,
                 fn ->
                   Imp.Predict.ProgramOfThought.new("x -> answer", output_field: [])
                 end
  end

  test "ProgramOfThought reports malformed generated code explicitly" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: %{not: "source"}} end]
    }

    program = Imp.Predict.ProgramOfThought.new("x -> answer", lm: lm)

    assert {:error, {:invalid_generated_program, %{not: "source"}}} =
             Imp.Predict.ProgramOfThought.call(program, %{x: 3})
  end

  test "ProgramOfThought projects and validates typed multi-output map results" do
    assert_multi_output_contract(fn source ->
      lm = static_program_lm(source)
      Imp.Predict.ProgramOfThought.new("x: int -> doubled: int, label: string", lm: lm)
    end)
  end

  test "CodeAct projects and validates typed multi-output map results" do
    assert_multi_output_contract(fn source ->
      lm = static_program_lm(source)
      Imp.Predict.CodeAct.new("x: int -> doubled: int, label: string", [], lm: lm)
    end)
  end

  test "CodeAct loops through tool observations before evaluating a program" do
    actions = [
      %{tool: "lookup", arguments: %{"key" => "n"}},
      %{program: "observation + 1"}
    ]

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_actions)
          Process.put(:code_act_actions, rest)
          action
        end
      ]
    }

    lookup = Imp.Tool.new(:lookup, "lookup a number", fn %{key: "n"} -> 41 end)
    Process.put(:code_act_actions, actions)

    code_act = Imp.Predict.CodeAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.Predict.CodeAct.call(code_act, %{question: "life?"})
    assert Imp.Prediction.get(prediction, :answer) == 42
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
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_actions)
          Process.put(:code_act_actions, rest)
          action
        end
      ]
    }

    lookup = Imp.Tool.new(:lookup, "lookup a number", fn %{key: "n"} -> 41 end)
    Process.put(:code_act_actions, actions)

    code_act = Imp.Predict.CodeAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.Predict.CodeAct.call(code_act, %{question: "life?"})
    assert Imp.Prediction.get(prediction, :answer) == 42

    assert [
             %{action: :tool, input: %{arguments: %{key: "n"}}},
             %{action: :program}
           ] = prediction.metadata.code_act_trace
  after
    Process.delete(:code_act_actions)
  end

  test "CodeAct fails immediately on unknown denied or crashing tools with traces" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:code_act_failure_actions)
          Process.put(:code_act_failure_actions, rest)
          action
        end
      ]
    }

    Process.put(:code_act_failure_actions, [%{tool: "missing", arguments: %{}}])
    unknown = Imp.Predict.CodeAct.new("question -> answer", [], lm: lm)

    assert {:error,
            {:code_act_tool_error, {:unknown_tool, "missing"},
             [%{action: :tool, output: {:error, {:unknown_tool, "missing"}}}]}} =
             Imp.Predict.CodeAct.call(unknown, %{question: "q"})

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> "should not run" end)
    Process.put(:code_act_failure_actions, [%{tool: "lookup", arguments: %{}}])

    denied =
      Imp.Predict.CodeAct.new("question -> answer", [lookup],
        lm: lm,
        tool_policy: [],
        max_iters: 2
      )

    assert {:error,
            {:code_act_tool_error, {:tool_authorization_denied, :lookup, :tool_policy},
             [
               %{
                 action: :tool,
                 output: {:error, {:tool_authorization_denied, :lookup, :tool_policy}}
               }
             ]}} =
             Imp.Predict.CodeAct.call(denied, %{question: "q"})

    boom = Imp.Tool.new(:boom, "boom", fn _args -> raise "tool exploded" end)
    Process.put(:code_act_failure_actions, [%{tool: "boom", arguments: %{}}])
    crashing = Imp.Predict.CodeAct.new("question -> answer", [boom], lm: lm, max_iters: 2)

    assert {:error,
            {:code_act_tool_error, {:tool_error, :boom, %RuntimeError{message: "tool exploded"}},
             [
               %{
                 action: :tool,
                 output: {:error, {:tool_error, :boom, %RuntimeError{message: "tool exploded"}}}
               }
             ]}} =
             Imp.Predict.CodeAct.call(crashing, %{question: "q"})
  after
    Process.delete(:code_act_failure_actions)
  end

  test "CodeAct sandbox rejection includes redacted trace context" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{program: "System.cmd(\"echo\", [])"}
        end
      ]
    }

    code_act = Imp.Predict.CodeAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:code_act_sandbox_error, {:unsafe_ast, _ast}, [trace]}} =
             Imp.Predict.CodeAct.call(code_act, %{question: "q"})

    assert %{
             action: :program,
             input: "System.cmd(\"echo\", [])",
             output: {:error, {:unsafe_ast, _}}
           } =
             trace
  end

  test "CodeAct zero max_iters fails before calling the planner" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :code_act_lm_called)
          %{program: "1 + 1"}
        end
      ]
    }

    code_act = Imp.Predict.CodeAct.new("question -> answer", [], lm: lm, max_iters: 0)

    assert {:error, {:code_act_max_iters, 0, []}} =
             Imp.Predict.CodeAct.call(code_act, %{question: "q"})

    refute_received :code_act_lm_called
  end

  test "CodeAct constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3: expected keyword options/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", [], %{lm: nil})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3 expects tools to be a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3 expects tools to be a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3: invalid value for :max_iters option: expected non negative integer/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", [], max_iters: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", [],
                     tool_policy: %{only: :lookup}
                   )
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.CodeAct\.new\/3: invalid value for :output_field option: expected an atom\/string field name/,
                 fn ->
                   Imp.Predict.CodeAct.new("question -> answer", [], output_field: [])
                 end

    code_act = Imp.Predict.CodeAct.new("question -> answer", [], lm: nil)

    assert {:error, {:invalid_code_act_inputs, message}} =
             Imp.Predict.CodeAct.call(code_act, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_code_act_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.Predict.CodeAct.call(code_act, [:not_a_pair])
  end

  defp assert_multi_output_contract(build_program) do
    valid = build_program.(~s(%{"doubled" => x * 2, label: "six"}))
    assert {:ok, prediction} = Imp.call(valid, %{x: 3})
    assert Imp.Prediction.get(prediction, :doubled) == 6
    assert Imp.Prediction.get(prediction, :label) == "six"

    missing = build_program.(~s(%{doubled: x * 2}))
    assert {:error, {:missing_output_fields, [:label]}} = Imp.call(missing, %{x: 3})

    unknown = build_program.(~s(%{doubled: x * 2, label: "six", extra: true}))
    assert {:error, {:unknown_output_fields, ["extra"]}} = Imp.call(unknown, %{x: 3})

    invalid = build_program.(~s(%{doubled: "six", label: "six"}))

    assert {:error,
            {:invalid_output_fields,
             [%{field: :doubled, rule: :type, message: "expected integer"}]}} =
             Imp.call(invalid, %{x: 3})

    scalar = build_program.("x * 2")

    assert {:error, {:invalid_program_outputs, {:expected_map, [:doubled, :label], 6}}} =
             Imp.call(scalar, %{x: 3})
  end

  defp static_program_lm(source) do
    %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: source} end]
    }
  end

  test "streaming exposes predictions as an enumerable" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]
    }

    program = Imp.predict("question -> answer", lm: lm)

    assert Imp.Streaming.collect(program, %{question: "runtime?"}) == "beam"

    assert Enum.take(Imp.Streaming.stream(program, %{question: "runtime?"}), 2) == [
             "b",
             "e"
           ]

    assert [
             %{field: :answer, value: "beam"},
             %{field: :rationale, value: "fast"}
           ] =
             Imp.Streaming.incremental_fields(
               ["[[ ## ans", "wer ## ]]beam", "[[ ## rationale ## ]]fast"],
               "question -> answer, rationale"
             )
  end

  test "streaming helpers validate owned options and provider-stream inputs" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "beam"} end]}
    program = Imp.predict("question -> answer", lm: lm)

    assert_raise ArgumentError, ~r/Imp\.Streaming\.stream\/3: expected keyword options/, fn ->
      Imp.Streaming.stream(program, %{question: "q"}, %{provider_stream: true}) |> Enum.to_list()
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Streaming\.stream\/3: invalid value for :chunker option: expected nil or an arity-1 function/,
                 fn ->
                   Imp.Streaming.stream(program, %{question: "q"}, chunker: :not_a_function)
                   |> Enum.to_list()
                 end

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk: {:error, {:invalid_stream_inputs, "expected inputs as {key, value} pairs"}},
               done: true
             }
           ] =
             Imp.Streaming.stream(program, [:not_a_pair], provider_stream: true)
             |> Enum.to_list()

    assert Imp.Streaming.collect(program, %{question: "q"},
             provider_stream: true,
             temperature: 0
           ) ==
             "beam"
  end

  test "provider streaming reports LM misconfiguration as error chunks" do
    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :lm option: expected configured LM :opts to be a keyword list/,
                 fn ->
                   Imp.predict("question -> answer",
                     lm: %{
                       module: Imp.LM.Static,
                       opts: %{handler: fn _messages, _opts -> %{answer: "ok"} end}
                     }
                   )
                 end

    bad_handler =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: :not_a_function]}
      )

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk: {:error, {:lm_failed, Imp.LM.Static, %ArgumentError{message: message}}},
               done: true
             }
           ] =
             Imp.Streaming.stream(bad_handler, %{question: "q"}, provider_stream: true)
             |> Enum.to_list()

    assert message =~ "expects :handler"

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :lm option: expected nil, an LM module/,
                 fn -> Imp.predict("question -> answer", lm: %{provider: :missing}) end
  end

  test "provider streaming reports adapter setup failures as error chunks" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}

    raising_format = Imp.predict("question -> answer", lm: lm, adapter: StreamingRaisingAdapter)

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk:
                 {:error,
                  {:adapter_format_failed, StreamingRaisingAdapter,
                   %RuntimeError{message: "streaming format exploded"}}},
               done: true
             }
           ] =
             Imp.Streaming.stream(raising_format, %{question: "q"}, provider_stream: true)
             |> Enum.to_list()

    invalid_lm_opts =
      Imp.predict("question -> answer", lm: lm, adapter: StreamingInvalidLMOptsAdapter)

    assert [
             %Imp.Streaming.Messages.StreamResponse{
               chunk:
                 {:error,
                  {:invalid_adapter_lm_opts, StreamingInvalidLMOptsAdapter, %{response_format: _}}},
               done: true
             }
           ] =
             Imp.Streaming.stream(invalid_lm_opts, %{question: "q"}, provider_stream: true)
             |> Enum.to_list()

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.Predict\.new\/2: invalid value for :adapter option: expected an adapter module exporting format\/3 and parse\/3/,
                 fn ->
                   Imp.predict("question -> answer",
                     lm: lm,
                     adapter: :"Elixir.MissingStreamAdapter"
                   )
                 end
  end

  test "provider streaming applies adapter supplied LM options" do
    owner = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          send(owner, {:streaming_lm_opts, opts})
          %{answer: "ok"}
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: lm, adapter: StreamingLMOptsAdapter)

    assert [%Imp.Prediction{} = prediction] =
             Imp.Streaming.stream(program, %{question: "q"}, provider_stream: true)
             |> Enum.to_list()

    assert Imp.get(prediction, :answer) == "unused"

    assert_received {:streaming_lm_opts, opts}
    assert Keyword.fetch!(opts, :marker) == :from_adapter
  end

  test "streaming fallback collects structured outputs in signature order" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{second: "two", first: "one"}
        end
      ]
    }

    program = Imp.predict("question -> first, second", lm: lm)

    assert Imp.Streaming.collect(program, %{question: "order?"}) == "onetwo"
    assert Enum.take(Imp.Streaming.stream(program, %{question: "order?"}), 6) == ~w(o n e t w o)
  end

  test "provider streaming executes composed built-in programs and returns their final prediction" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{program: "n * 2"} end)
    program = Imp.program_of_thought("n: integer -> doubled: integer", lm: lm)

    assert Imp.Streaming.collect(program, %{n: 2}, provider_stream: true) == "4"
  end

  test "streaming fallback collects wrapper outputs through their task contracts" do
    pot_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    pot = Imp.program_of_thought("x -> doubled", lm: pot_lm, output_field: :doubled)
    assert Imp.Streaming.collect(pot, %{x: 21}) == "42"

    cot_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris", reasoning: "known"} end]
    }

    cot = Imp.chain_of_thought("question -> answer", lm: cot_lm)
    assert Imp.Streaming.collect(cot, %{question: "France capital?"}) == "knownParis"
  end

  test "dataset loaders produce examples with declared inputs" do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-dataset-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":"3+3?","answer":"6"}\n))

    examples = Imp.Datasets.gsm8k(path)
    assert length(examples) == 2
    assert Imp.Example.to_map(Imp.Example.inputs(hd(examples))) == %{question: "2+2?"}

    File.rm(path)
  end

  test "advanced optimizers return executable compiled programs" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.Example.with_inputs(:question),
      Imp.example(question: "square root of 16?", answer: "4")
      |> Imp.Example.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "2 plus 2?", answer: "4")
      |> Imp.Example.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)

    proposal_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Jason.encode!(%{
            "proposed_instruction" => "Answer exactly.",
            "proposed_prefix_for_output_field" => "Answer:"
          })
        end
      )

    reflection_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{instruction: "Answer exactly."} end)

    compiled =
      [
        Imp.Optimizer.COPRO.new(metric,
          breadth: 3,
          depth: 1,
          proposer_lm: proposal_lm
        ),
        Imp.Optimizer.MIPROv2.new(metric,
          auto: nil,
          num_candidates: 3,
          num_trials: 3,
          max_bootstrapped_demos: 0,
          max_labeled_demos: 1,
          minibatch: false
        ),
        Imp.Optimizer.SIMBA.new(metric, bsize: 2, max_steps: 2, max_demos: 1),
        Imp.Optimizer.GEPA.new(metric, generations: 2, reflection_lm: reflection_lm),
        Imp.Optimizer.SignatureOptimizer.new(metric)
      ]
      |> Enum.map(fn optimizer ->
        optimizer.__struct__.compile(optimizer, program, trainset, devset)
      end)

    assert Enum.all?(compiled, fn candidate ->
             {:ok, prediction} = Imp.Predict.Predict.call(candidate, %{question: "2+2?"})
             Imp.Prediction.get(prediction, :answer) == "4"
           end)
  end

  test "finetuning and GRPO require an explicit trainer backend" do
    lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
    program = Imp.predict("question -> answer", lm: lm)
    metric = Imp.Metrics.exact_match(:answer)

    trainset = [
      Imp.example(question: "2+2?", answer: "4") |> Imp.Example.with_inputs(:question)
    ]

    result =
      Imp.Optimizer.BootstrapFinetune.new(metric)
      |> Imp.Optimizer.BootstrapFinetune.compile(program, trainset)

    assert %{program: %Imp.Predict.Predict{}, error: :trainer_required} = result

    reward = fn example ->
      if Imp.Example.get(example, :answer) == "4", do: 1.0, else: 0.0
    end

    assert {:error, :trainer_required} =
             Imp.Optimizer.GRPO.new(reward)
             |> Imp.Optimizer.GRPO.compile(program, trainset)
  end

  test "save/load, embeddings, and structured adapters work" do
    # The program below is saved, so its LM comes from context: saving refuses
    # a Static-pinned program.
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> ~s({"answer":"ok"}) end]
    }

    program = Imp.predict("question -> answer", adapter: Imp.Adapter.JSON)

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-program-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.Predict.Predict.call(program, %{question: "ship?"})
             end)

    assert Imp.Prediction.get(prediction, :answer) == "ok"

    assert :ok = Imp.Saving.save!(program, path)
    assert %Imp.Predict.Predict{} = Imp.Saving.load!(path)
    File.rm(path)

    assert {:ok, [vector]} =
             Imp.Embeddings.embed(Imp.Embeddings.BagOfWords, ["hello hello beam"], dims: 8)

    assert length(vector) == 8

    # PlanFirst (the renamed plan-prepend Imp extension) still injects a plan
    # field through the Chat adapter.
    messages = Imp.Adapter.PlanFirst.format(Imp.signature("q -> a"), %{q: "x"}, [])
    assert Enum.any?(messages, &String.contains?(&1.content, "plan"))
  end

  test "TwoStep adapter is the faithful DSPy TwoStepAdapter contract" do
    signature = Imp.signature("question -> answer", "Answer the question.")

    # MAIN call: persona system message from field descriptions, plain
    # `name: value` user content — no [[ ## ]] markers anywhere.
    messages = Imp.Adapter.TwoStep.format(signature, %{question: "capital of France?"}, [])
    assert [%{role: :system, content: system}, %{role: :user, content: user}] = messages
    assert String.starts_with?(system, "You are a helpful assistant")
    assert system =~ "As input, you will be provided with:\n1. `question` (str):"
    assert system =~ "Specific instructions: Answer the question."
    assert user == "question: capital of France?"
    refute Enum.any?(messages, &String.contains?(&1.content, "[[ ##"))

    # parse without a configured extraction LM fails LOUDLY (nothing silent).
    assert {:error, {:two_step_extraction_lm_not_configured, _message}} =
             Imp.Adapter.TwoStep.parse(signature, "The answer is Paris.", [])

    # parse runs the SECOND extraction LM over the synthesized
    # `text -> outputs` signature via the ChatAdapter path.
    {:ok, calls} = Agent.start_link(fn -> [] end)

    extraction_lm = fn messages, _opts ->
      Agent.update(calls, &(&1 ++ [messages]))
      {:ok, "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"}
    end

    assert {:ok, prediction} =
             Imp.Settings.context([two_step_extraction_lm: extraction_lm], fn ->
               Imp.Adapter.TwoStep.parse(signature, "The answer is Paris.", [])
             end)

    assert Imp.Prediction.get(prediction, :answer) == "Paris"

    assert [
             [
               %{role: :system, content: extractor_system},
               %{role: :user, content: extractor_user}
             ]
           ] =
             Agent.get(calls, & &1)

    assert extractor_system =~ "Your input fields are:\n1. `text` (str):"

    assert extractor_system =~
             "The input is a text that should contain all the necessary information to produce the fields `answer`."

    assert extractor_user =~ "[[ ## text ## ]]\nThe answer is Paris."
    Agent.stop(calls)
  end

  test "embedding providers report invalid boundaries clearly" do
    assert_raise ArgumentError, ~r/Imp.Embeddings.embed\/3 expects keyword options/, fn ->
      Imp.Embeddings.embed(Imp.Embeddings.BagOfWords, ["beam"], %{dims: 8})
    end

    assert_raise ArgumentError,
                 ~r/Imp.Embeddings.embed\/3 expects texts to be a list of strings/,
                 fn ->
                   Imp.Embeddings.embed(Imp.Embeddings.BagOfWords, [:beam], dims: 8)
                 end

    assert {:error,
            {:embedding_provider_failed, Imp.Embeddings.BagOfWords,
             %ArgumentError{
               message:
                 "Imp.Embeddings.BagOfWords.embed/2: invalid value for :dims option: expected positive integer, got: 0"
             }}} =
             Imp.Embeddings.embed(Imp.Embeddings.BagOfWords, ["beam"], dims: 0)

    assert {:error, {:not_embedding_provider, :not_an_embedder}} =
             Imp.Embeddings.embed(:not_an_embedder, ["beam"], [])

    assert {:error, {:invalid_embedding_result, :not_a_result}} =
             Imp.Embeddings.embed(fn _texts, _opts -> :not_a_result end, ["beam"], [])

    assert {:error, {:invalid_embedding_result, [[1.0, "bad"]]}} =
             Imp.Embeddings.embed(fn _texts, _opts -> {:ok, [[1.0, "bad"]]} end, ["beam"], [])

    assert {:error, {:invalid_embedding_result, [[1.0]]}} =
             Imp.Embeddings.embed(
               fn _texts, _opts -> {:ok, [[1.0]]} end,
               ["beam", "elixir"],
               []
             )

    assert {:error, {:invalid_embedding_result, [[1.0], [2.0]]}} =
             Imp.Embeddings.embed(
               fn _texts, _opts -> {:ok, [[1.0], [2.0]]} end,
               ["beam"],
               []
             )

    assert {:error,
            {:embedding_provider_failed, :anonymous_embedder,
             %RuntimeError{message: "embed exploded"}}} =
             Imp.Embeddings.embed(fn _texts, _opts -> raise "embed exploded" end, ["beam"], [])

    assert {:error,
            {:embedding_provider_failed, RaisingEmbedder,
             %RuntimeError{message: "embed exploded"}}} =
             Imp.Embeddings.embed(RaisingEmbedder, ["beam"], [])
  end
end
