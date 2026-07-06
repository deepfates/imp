defmodule DachshundFacadeTest do
  use ExUnit.Case

  setup do
    Dachshund.configure(lm: nil, adapter: Dachshund.Adapter.Chat, retriever: nil)
    :ok
  end

  test "facade configures, builds, calls, and reads an Elixir-native program" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    Dachshund.configure(lm: lm)

    program = Dachshund.predict("question -> answer")

    assert {:ok, prediction} = Dachshund.call(program, %{question: "Capital of France?"})
    assert Dachshund.get(prediction, :answer) == "Paris"
  end

  test "facade exposes examples and predictions through one reader" do
    example = Dachshund.example(question: "2+2?", answer: "4")
    prediction = Dachshund.prediction(answer: "4")

    assert Dachshund.get(example, :question) == "2+2?"
    assert Dachshund.get(prediction, :answer) == "4"
    assert Dachshund.get(prediction, :missing, :default) == :default
  end

  test "call reports non-callable values instead of raising" do
    assert Dachshund.call(%{}, %{question: "q"}) == {:error, {:not_callable, %{}}}
  end

  test "canonical facade builds and calls directly" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    program = Dachshund.predict("question -> answer", lm: lm)

    assert {:ok, prediction} = Dachshund.call(program, %{question: "q"})
    assert Dachshund.get(prediction, :answer) == "ok"
  end
end
