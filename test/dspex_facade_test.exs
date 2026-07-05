defmodule DSPExFacadeTest do
  use ExUnit.Case

  setup do
    DSPEx.configure(lm: nil, adapter: DSPy.Adapter.Chat, retriever: nil)
    :ok
  end

  test "facade configures, builds, calls, and reads an Elixir-native program" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    DSPEx.configure(lm: lm)

    program = DSPEx.predict("question -> answer")

    assert {:ok, prediction} = DSPEx.call(program, %{question: "Capital of France?"})
    assert DSPEx.get(prediction, :answer) == "Paris"
  end

  test "facade exposes examples and predictions through one reader" do
    example = DSPEx.example(question: "2+2?", answer: "4")
    prediction = DSPEx.prediction(answer: "4")

    assert DSPEx.get(example, :question) == "2+2?"
    assert DSPEx.get(prediction, :answer) == "4"
    assert DSPEx.get(prediction, :missing, :default) == :default
  end

  test "call reports non-callable values instead of raising" do
    assert DSPEx.call(%{}, %{question: "q"}) == {:error, {:not_callable, %{}}}
  end

  test "historical package wrapper delegates to the canonical facade" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    program = DspyElixir.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DspyElixir.call(program, %{question: "q"})
    assert DspyElixir.get(prediction, :answer) == "ok"
  end
end
