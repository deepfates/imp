defmodule DSExFacadeTest do
  use ExUnit.Case

  setup do
    DSEx.configure(lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil)
    :ok
  end

  test "facade configures, builds, calls, and reads an Elixir-native program" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    DSEx.configure(lm: lm)

    program = DSEx.predict("question -> answer")

    assert {:ok, prediction} = DSEx.call(program, %{question: "Capital of France?"})
    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "facade exposes examples and predictions through one reader" do
    example = DSEx.example(question: "2+2?", answer: "4")
    prediction = DSEx.prediction(answer: "4")

    assert DSEx.get(example, :question) == "2+2?"
    assert DSEx.get(prediction, :answer) == "4"
    assert DSEx.get(prediction, :missing, :default) == :default
  end

  test "call reports non-callable values instead of raising" do
    assert DSEx.call(%{}, %{question: "q"}) == {:error, {:not_callable, %{}}}
  end

  test "canonical facade builds and calls directly" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "ok"
  end
end
