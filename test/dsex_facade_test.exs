defmodule DSExFacadeTest do
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
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "facade configures, builds, calls, and reads an Elixir-native program" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    DSEx.configure(lm: lm)

    program = DSEx.predict("question -> answer")

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "facade exposes examples and predictions through one reader" do
    example =
      DSEx.example(question: "2+2?", answer: "4")
      |> DSEx.with_inputs(:question)

    prediction = DSEx.prediction(answer: "4")

    assert DSEx.get(example, :question) == "2+2?"
    assert DSEx.get(prediction, :answer) == "4"
    assert DSEx.get(prediction, :missing, :default) == :default
    assert DSEx.to_map(prediction) == %{answer: "4"}
    assert DSEx.to_map(DSEx.inputs(example)) == %{question: "2+2?"}
    assert DSEx.to_map(DSEx.labels(example)) == %{answer: "4"}
  end

  test "facade readers report unsupported containers clearly" do
    assert_raise ArgumentError,
                 ~r/DSEx\.get\/3 expects a DSEx\.Prediction or DSEx\.Example/,
                 fn ->
                   DSEx.get(%{answer: "4"}, :answer)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.to_map\/1 expects a DSEx\.Prediction or DSEx\.Example/,
                 fn ->
                   DSEx.to_map(%{answer: "4"})
                 end
  end

  test "facade settings report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/DSEx\.configure\/1 expects a map or settings pair list/, fn ->
      DSEx.configure(:not_settings)
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.configure\/1 expects settings as \{key, value\} pairs/,
                 fn ->
                   DSEx.configure([:not_a_pair])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.context\/2 expects settings as a map or settings pair list/,
                 fn ->
                   DSEx.context(:not_settings, fn -> :ok end)
                 end

    assert_raise ArgumentError, ~r/DSEx\.context\/2 expects a zero-arity function/, fn ->
      DSEx.context([lm: :local], :not_a_function)
    end
  end

  test "invalid context settings do not leak process-local overrides" do
    DSEx.configure(lm: :global)

    assert_raise ArgumentError,
                 ~r/DSEx\.context\/2 expects settings as \{key, value\} pairs/,
                 fn ->
                   DSEx.context([:not_a_pair], fn -> :ok end)
                 end

    assert DSEx.settings().lm == :global
  end

  test "facade attaches demos and builds tools" do
    program = DSEx.predict("question -> answer")
    cot = DSEx.chain_of_thought("question -> answer")
    pot = DSEx.program_of_thought("question -> answer")
    code_act = DSEx.code_act("question -> answer")
    rag = DSEx.rag(program, DSEx.Retrieve.Memory.new([%{text: "2+2 is 4"}]))
    demo = DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)

    assert %{demos: [^demo]} = DSEx.with_demos(program, [demo])
    assert %{predict: %{demos: [^demo]}} = DSEx.with_demos(cot, [demo])
    assert %{predict: %{demos: [^demo]}} = DSEx.with_demos(pot, [demo])

    assert %{program_of_thought: %{predict: %{demos: [^demo]}}} =
             DSEx.with_demos(code_act, [demo])

    assert %{program: %{demos: [^demo]}} = DSEx.with_demos(rag, [demo])
    assert %{demos: [^demo]} = DSEx.with_demos(DSEx.example(question: "q"), demo)

    tool = DSEx.tool(:lookup, "lookup", fn %{key: "x"} -> "y" end)
    assert DSEx.Tool.call(tool, %{key: "x"}) == "y"
  end

  test "internal program access separates task and LM-facing signatures" do
    pot =
      "x, context -> doubled"
      |> DSEx.program_of_thought(output_field: :doubled)
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "double x"}]))

    assert "x, context -> doubled" =
             pot
             |> DSEx.ProgramAccess.task_signature()
             |> DSEx.Signature.to_spec()

    assert "x, context -> program, tool, arguments" =
             pot
             |> DSEx.ProgramAccess.lm_signature()
             |> DSEx.Signature.to_spec()

    assert DSEx.ProgramAccess.output_names(pot) == [:doubled]
    assert DSEx.ProgramAccess.provider_stream_predict(pot) == nil

    cot = DSEx.chain_of_thought("question -> answer")

    assert "question -> reasoning, answer" =
             cot
             |> DSEx.ProgramAccess.task_signature()
             |> DSEx.Signature.to_spec()

    assert %DSEx.Predict.Predict{} = DSEx.ProgramAccess.provider_stream_predict(cot)
  end

  test "facade normalizes plain demo data and rejects malformed demos clearly" do
    program = DSEx.predict("question -> answer")

    assert %{demos: [%DSEx.Example{} = demo]} =
             DSEx.with_demos(program, question: "2+2?", answer: "4")

    assert DSEx.Example.to_map(demo) == %{question: "2+2?", answer: "4"}

    assert %{demos: [%DSEx.Example{}, %DSEx.Example{}]} =
             DSEx.with_demos(program, [
               %{question: "2+2?", answer: "4"},
               [question: "3+3?", answer: "6"]
             ])

    assert_raise ArgumentError,
                 ~r/DSEx.Predict.Predict.with_demos\/2 expects demos as DSEx.Example structs/,
                 fn ->
                   DSEx.with_demos(program, [:not_a_demo])
                 end
  end

  test "facade-attached ProgramOfThought demos are portable" do
    demo = DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)

    loaded =
      "question -> answer"
      |> DSEx.program_of_thought()
      |> DSEx.with_demos([demo])
      |> DSEx.Saving.dump()
      |> DSEx.Saving.load()

    assert %DSEx.Predict.ProgramOfThought{predict: %{demos: [loaded_demo]}} = loaded
    assert DSEx.Example.to_map(loaded_demo) == DSEx.Example.to_map(demo)
    assert loaded_demo.input_keys == demo.input_keys
  end

  test "facade evaluates and optimizes through the golden path" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "Capital of France?", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    devset = [
      DSEx.example(question: "Eiffel Tower city?", answer: "Paris") |> DSEx.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    assert %DSEx.Evaluate.Result{score: 1.0} = DSEx.evaluate(program, devset, metric)

    assert %{demos: [_]} =
             DSEx.optimize(program, DSEx.Optimizer.LabeledFewShot.new(k: 1), trainset)

    random_search = DSEx.Optimizer.RandomSearch.new(metric, candidates: 1, demos_per_candidate: 1)
    compiled = DSEx.optimize(program, random_search, trainset, devset)

    assert %DSEx.Optimizer.Report{optimizer: :random_search} =
             DSEx.Optimizer.Report.fetch(compiled)
  end

  test "facade reports unsupported demos and optimizers clearly" do
    assert_raise ArgumentError, ~r/DSEx\.with_demos\/2 supports Predict/, fn ->
      DSEx.with_demos(:not_a_program, [])
    end

    program = DSEx.predict("question -> answer")

    assert_raise ArgumentError, ~r/DSEx\.optimize\/3 expects an optimizer struct/, fn ->
      DSEx.optimize(program, :not_an_optimizer, [])
    end

    assert_raise ArgumentError, ~r/DSEx\.optimize\/4 expects an optimizer struct/, fn ->
      DSEx.optimize(program, :not_an_optimizer, [], [])
    end
  end

  test "call reports non-callable values instead of raising" do
    assert DSEx.call(%{}, %{question: "q"}) == {:error, {:not_callable, %{}}}
  end

  test "call reports program exceptions and throws as structured errors" do
    assert DSEx.call(%RaisingProgram{}, %{question: "q"}) ==
             {:error, {:module_call_failed, RaisingProgram, "program exploded"}}

    assert DSEx.call(%ThrowingProgram{}, %{question: "q"}) ==
             {:error, {:module_call_failed, ThrowingProgram, "{:throw, :program_thrown}"}}
  end

  test "call reports invalid module return shapes at the public boundary" do
    assert DSEx.call(%InvalidOkProgram{}, %{question: "q"}) ==
             {:error,
              {:invalid_module_prediction, InvalidOkProgram, "%{answer: \"not a prediction\"}"}}

    assert DSEx.call(%InvalidReturnProgram{}, %{question: "q"}) ==
             {:error, {:invalid_module_result, InvalidReturnProgram, ":not_a_module_result"}}
  end

  test "canonical facade builds and calls directly" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "ok"
  end
end
