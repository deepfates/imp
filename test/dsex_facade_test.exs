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

  test "facade attaches demos and builds tools" do
    program = DSEx.predict("question -> answer")
    cot = DSEx.chain_of_thought("question -> answer")
    rag = DSEx.rag(program, DSEx.Retrieve.Memory.new([%{text: "2+2 is 4"}]))
    demo = DSEx.example(question: "2+2?", answer: "4") |> DSEx.with_inputs(:question)

    assert %{demos: [^demo]} = DSEx.with_demos(program, [demo])
    assert %{predict: %{demos: [^demo]}} = DSEx.with_demos(cot, [demo])
    assert %{program: %{demos: [^demo]}} = DSEx.with_demos(rag, [demo])
    assert %{demos: [^demo]} = DSEx.with_demos(DSEx.example(question: "q"), demo)

    tool = DSEx.tool(:lookup, "lookup", fn %{key: "x"} -> "y" end)
    assert DSEx.Tool.call(tool, %{key: "x"}) == "y"
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
