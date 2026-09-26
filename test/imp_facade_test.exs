defmodule ImpFacadeTest do
  use ExUnit.Case

  defmodule RaisingProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: raise("program exploded")
  end

  defmodule ThrowingProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: throw(:program_thrown)
  end

  defmodule InvalidOkProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: {:ok, %{answer: "not a prediction"}}
  end

  defmodule InvalidReturnProgram do
    defstruct []

    def call(%__MODULE__{}, _inputs), do: :not_a_module_result
  end

  setup do
    Imp.configure(lm: nil, adapter: Imp.Adapter.Chat)
    # Restore the global Imp.Settings Agent to defaults after every test (a
    # non-default :lm set below must not leak into later modules). See dee-fqsr.
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "facade configures, builds, calls, and reads an Elixir-native program" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    Imp.configure(lm: lm)

    program = Imp.predict("question -> answer")

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "facade streams and collects one program call" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer", lm: lm)

    assert Imp.stream(program, %{question: "Capital of France?"}) |> Enum.to_list() ==
             ["P", "a", "r", "i", "s"]

    assert Imp.stream(program, %{question: "Capital of France?"}, chunker: &[&1])
           |> Enum.to_list() == ["Paris"]

    assert Imp.collect(program, %{question: "Capital of France?"}) == "Paris"

    failing = Imp.LM.Static.new(handler: fn _messages, _opts -> raise "provider down" end)

    failing_program = Imp.predict("question -> answer", lm: failing)

    assert {:error, _reason} = Imp.collect(failing_program, %{question: "Capital of France?"})
  end

  test "facade exposes examples and predictions through one reader" do
    example =
      Imp.example(question: "2+2?", answer: "4")
      |> Imp.with_inputs(:question)

    prediction = Imp.prediction(answer: "4")

    assert Imp.get(example, :question) == "2+2?"
    assert Imp.get(prediction, :answer) == "4"
    assert Imp.get(prediction, :missing, :default) == :default
    assert Imp.to_map(prediction) == %{answer: "4"}
    assert Imp.to_map(Imp.inputs(example)) == %{question: "2+2?"}
    assert Imp.to_map(Imp.labels(example)) == %{answer: "4"}
  end

  test "facade readers report unsupported containers clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.get\/3 expects an Imp\.Prediction or Imp\.Example/,
                 fn ->
                   Imp.get(%{answer: "4"}, :answer)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.to_map\/1 expects an Imp\.Prediction or Imp\.Example/,
                 fn ->
                   Imp.to_map(%{answer: "4"})
                 end
  end

  test "facade settings report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/Imp\.configure\/1 expects a map or settings pair list/, fn ->
      Imp.configure(:not_settings)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.configure\/1 expects settings as \{key, value\} pairs/,
                 fn ->
                   Imp.configure([:not_a_pair])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.context\/2 expects settings as a map or settings pair list/,
                 fn ->
                   Imp.context(:not_settings, fn -> :ok end)
                 end

    assert_raise ArgumentError, ~r/Imp\.context\/2 expects a zero-arity function/, fn ->
      Imp.context([lm: :local], :not_a_function)
    end
  end

  test "invalid context settings do not leak process-local overrides" do
    Imp.configure(lm: :global)

    assert_raise ArgumentError,
                 ~r/Imp\.context\/2 expects settings as \{key, value\} pairs/,
                 fn ->
                   Imp.context([:not_a_pair], fn -> :ok end)
                 end

    assert Imp.settings().lm == :global
  end

  test "facade attaches demos and builds tools" do
    program = Imp.predict("question -> answer")
    cot = Imp.chain_of_thought("question -> answer")
    pot = Imp.program_of_thought("question -> answer")
    code_act = Imp.code_act("question -> answer")
    rag = Imp.rag(program, Imp.memory([%{text: "2+2 is 4"}]))
    demo = Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)

    assert %{demos: [^demo]} = Imp.with_demos(program, [demo])
    assert %{predict: %{demos: [^demo]}} = Imp.with_demos(cot, [demo])
    assert %{predict: %{demos: [^demo]}} = Imp.with_demos(pot, [demo])

    assert %{program_of_thought: %{predict: %{demos: [^demo]}}} =
             Imp.with_demos(code_act, [demo])

    assert %{program: %{demos: [^demo]}} = Imp.with_demos(rag, [demo])

    assert %{program: %{demos: [^demo]}} =
             program
             |> Imp.best_of_n(fn _example, _prediction -> 1.0 end)
             |> Imp.with_demos([demo])

    assert %{demos: [^demo]} = Imp.with_demos(Imp.example(question: "q"), demo)

    tool = Imp.tool(:lookup, "lookup", fn %{key: "x"} -> "y" end)
    assert Imp.Tool.call(tool, %{key: "x"}) == "y"
  end

  test "facade attaches demos through compiled ensembles and child wrappers" do
    demo =
      Imp.example(question: "demo marker", answer: "demonstrated")
      |> Imp.with_inputs(:question)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          %{answer: if(prompt =~ "demo marker", do: "demonstrated", else: "missing")}
        end
      )

    child = Imp.predict("question -> answer", lm: lm)

    ensemble =
      Imp.Optimizer.Ensemble.new(deterministic: true)
      |> Imp.Optimizer.Ensemble.compile([
        child,
        Imp.best_of_n(child, fn _inputs, _prediction -> 1.0 end, n: 1)
      ])
      |> Imp.with_demos([demo])

    assert {:ok, prediction} = Imp.call(ensemble, %{question: "consumer question"})

    assert prediction
           |> Imp.get(:outputs)
           |> Enum.map(fn {:ok, child_prediction} -> Imp.get(child_prediction, :answer) end) ==
             ["demonstrated", "demonstrated"]
  end

  test "facade builds and calls local memory retrievers" do
    retriever = Imp.memory([[text: "France has capital Paris"]], k: 1)

    assert {:ok, [%{text: "France has capital Paris", score: score}]} =
             Imp.retrieve(retriever, "capital France")

    assert score > 0

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program =
      "question, context -> answer"
      |> Imp.predict(lm: lm)
      |> Imp.rag(retriever, k: 1)

    assert {:ok, prediction} = Imp.call(program, %{question: "capital France"})
    assert Imp.get(prediction, :answer) == "Paris"
  end

  test "internal program access separates task and LM-facing signatures" do
    pot =
      "x, context -> doubled"
      |> Imp.program_of_thought(output_field: :doubled)
      |> Imp.rag(Imp.memory([%{text: "double x"}]))

    assert "x, context -> doubled" =
             pot
             |> Imp.ProgramAccess.task_signature()
             |> Imp.Signature.to_spec()

    assert "x, context -> program, tool, arguments" =
             pot
             |> Imp.ProgramAccess.lm_signature()
             |> Imp.Signature.to_spec()

    assert Imp.ProgramAccess.output_names(pot) == [:doubled]

    cot = Imp.chain_of_thought("question -> answer")

    assert "question -> reasoning, answer" =
             cot
             |> Imp.ProgramAccess.task_signature()
             |> Imp.Signature.to_spec()
  end

  test "facade normalizes plain demo data and rejects malformed demos clearly" do
    program = Imp.predict("question -> answer")

    assert %{demos: [%Imp.Example{} = demo]} =
             Imp.with_demos(program, question: "2+2?", answer: "4")

    assert Imp.Example.to_map(demo) == %{question: "2+2?", answer: "4"}

    assert %{demos: [%Imp.Example{}, %Imp.Example{}]} =
             Imp.with_demos(program, [
               %{question: "2+2?", answer: "4"},
               [question: "3+3?", answer: "6"]
             ])

    assert_raise ArgumentError,
                 ~r/Imp.Predict.with_demos\/2 expects demos as Imp.Example structs/,
                 fn ->
                   Imp.with_demos(program, [:not_a_demo])
                 end
  end

  test "facade-attached ProgramOfThought demos are portable" do
    demo = Imp.example(question: "2+2?", answer: "4") |> Imp.with_inputs(:question)

    loaded =
      "question -> answer"
      |> Imp.program_of_thought()
      |> Imp.with_demos([demo])
      |> Imp.dump()
      |> Imp.load!()

    assert %Imp.Predict.ProgramOfThought{predict: %{demos: [loaded_demo]}} = loaded
    assert Imp.Example.to_map(loaded_demo) == Imp.Example.to_map(demo)
    assert loaded_demo.input_keys == demo.input_keys
  end

  test "facade saves and loads portable programs" do
    # A portable program is dynamic or ReqLLM-pinned: dumping refuses a
    # Static-pinned program.
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer")
    loaded = program |> Imp.dump() |> Imp.load!()

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(loaded, %{question: "Capital of France?"})
             end)

    assert Imp.get(prediction, :answer) == "Paris"

    path =
      Path.join(System.tmp_dir!(), "imp-facade-save-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.save!(program, path)
    assert %Imp.Predict{} = Imp.read!(path)
  end

  test "Imp.react builds the ReActV2 agent under one facade name" do
    assert %Imp.Predict.ReActV2{} = Imp.react("question -> answer", [])
    refute function_exported?(Imp, :react_v2, 3)
  end

  test "load returns a tagged result and load! raises; read! reads a saved file" do
    state = Imp.predict("question -> answer") |> Imp.dump()

    assert {:ok, %Imp.Predict{}} = Imp.load(state)
    assert %Imp.Predict{} = Imp.load!(state)

    assert {:error, %ArgumentError{message: message}} = Imp.load(%{"type" => "no_such_program"})
    assert message =~ "unsupported saved Imp program type"
    assert {:error, %ArgumentError{}} = Imp.load(:not_a_map)
    assert_raise ArgumentError, fn -> Imp.load!(%{"type" => "no_such_program"}) end

    path =
      Path.join(System.tmp_dir!(), "imp-facade-read-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    assert :ok = Imp.save!(Imp.predict("question -> answer"), path)
    assert %Imp.Predict{} = Imp.read!(path)

    # A path is not a saved program; reading files is `read!/2`'s job, and the
    # error says so.
    assert {:error, %ArgumentError{message: message}} = Imp.load(path)
    assert message =~ "use Imp.read!/1"
  end

  test "facade evaluates and optimizes through the golden path" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "Capital of France?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    devset = [
      Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    metric = Imp.exact_match(:answer)

    assert %Imp.Evaluate.Result{score: 1.0} = Imp.evaluate(program, devset, metric)

    assert %{demos: [_]} =
             Imp.optimize!(program, Imp.Optimizer.LabeledFewShot.new(k: 1), trainset)

    random_search =
      Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
        num_candidate_programs: 1,
        max_bootstrapped_demos: 1
      )

    compiled = Imp.optimize!(program, random_search, trainset, devset)

    assert %Imp.Optimizer.Report{optimizer: :random_search} =
             Imp.Optimizer.Report.fetch(compiled)
  end

  test "facade exposes common metric helpers" do
    example = Imp.example(answer: "Paris")
    prediction = Imp.prediction(answer: "paris")

    assert Imp.exact_match(:answer).(example, prediction)

    assert %{score: 1.0, metadata: %{"exact_match" => true}} =
             Imp.extractive_qa("Paris", "paris")

    assert %{score: 1.0, metadata: %{"correct" => true}} =
             Imp.classification("Positive", "positive")

    report =
      Imp.classification_report([
        %{prediction: "yes", label: "yes"},
        %{prediction: "no", label: "yes"}
      ])

    assert report["accuracy"] == 0.5
  end

  test "optimize returns tuples and optimize! raises, mirroring train" do
    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)
      )

    trainset = [
      Imp.example(question: "Eiffel Tower city?", answer: "Paris") |> Imp.with_inputs(:question)
    ]

    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 1)

    assert {:ok, %{demos: [_]}} = Imp.optimize(program, optimizer, trainset)

    assert {:error, {:optimizer_kind_mismatch, :program, :training}} =
             Imp.optimize(
               program,
               Imp.Optimizer.BootstrapFinetune.new(Imp.exact_match(:answer)),
               trainset
             )

    assert_raise ArgumentError, ~r/received a training optimizer; use Imp\.train\/4/, fn ->
      Imp.optimize!(
        program,
        Imp.Optimizer.BootstrapFinetune.new(Imp.exact_match(:answer)),
        trainset
      )
    end
  end

  test "facade reports unsupported demos and optimizers clearly" do
    assert_raise ArgumentError, ~r/Imp\.with_demos\/2 supports Predict/, fn ->
      Imp.with_demos(:not_a_program, [])
    end

    program = Imp.predict("question -> answer")

    assert_raise ArgumentError, ~r/Imp\.optimize!\/3 expects an optimizer struct/, fn ->
      Imp.optimize!(program, :not_an_optimizer, [])
    end

    assert_raise ArgumentError, ~r/Imp\.optimize!\/4 expects an optimizer struct/, fn ->
      Imp.optimize!(program, :not_an_optimizer, [], [])
    end
  end

  test "call reports non-callable values instead of raising" do
    assert Imp.call(%{}, %{question: "q"}) == {:error, {:not_callable, %{}}}
  end

  test "call reports program exceptions and throws as structured errors" do
    assert Imp.call(%RaisingProgram{}, %{question: "q"}) ==
             {:error,
              {:module_call_failed, RaisingProgram, %RuntimeError{message: "program exploded"}}}

    assert Imp.call(%ThrowingProgram{}, %{question: "q"}) ==
             {:error, {:module_call_failed, ThrowingProgram, {:throw, :program_thrown}}}
  end

  test "call reports invalid module return shapes at the public boundary" do
    assert Imp.call(%InvalidOkProgram{}, %{question: "q"}) ==
             {:error,
              {:invalid_module_prediction, InvalidOkProgram, "%{answer: \"not a prediction\"}"}}

    assert Imp.call(%InvalidReturnProgram{}, %{question: "q"}) ==
             {:error, {:invalid_module_result, InvalidReturnProgram, ":not_a_module_result"}}
  end

  test "canonical facade builds and calls directly" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)

    program = Imp.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "ok"
  end
end
