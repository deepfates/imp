defmodule Imp.FieldKeyTypeTest do
  use ExUnit.Case, async: true

  # `:question` and `:answer` exist as atoms in every VM that loaded this file,
  # which is exactly when a string key used to be turned into one.
  @loaded_atoms [:question, :answer]

  test "an example keeps string keys as strings even when the atom exists" do
    assert @loaded_atoms == [:question, :answer]

    example = Imp.Example.new(%{"question" => "2+2?", "answer" => "4"})

    assert Imp.Example.to_map(example) == %{"question" => "2+2?", "answer" => "4"}
    assert Imp.Example.get(example, :question) == "2+2?"
    assert Imp.Example.get(example, "question") == "2+2?"
    assert Imp.Example.fetch!(example, :answer) == "4"
  end

  test "input marking compares keys by text" do
    example =
      %{"question" => "2+2?", "answer" => "4"}
      |> Imp.Example.new()
      |> Imp.Example.with_inputs(:question)

    assert Imp.Example.to_map(Imp.Example.inputs(example)) == %{"question" => "2+2?"}
    assert Imp.Example.to_map(Imp.Example.labels(example)) == %{"answer" => "4"}
  end

  test "put replaces a field under the key it already has" do
    example = Imp.Example.new(%{"answer" => "4"}) |> Imp.Example.put(:answer, "5")
    assert Imp.Example.to_map(example) == %{"answer" => "5"}

    example = Imp.Example.delete(example, :answer)
    assert Imp.Example.to_map(example) == %{}
  end

  test "a prediction keeps string keys as strings even when the atom exists" do
    prediction = Imp.Prediction.new(%{"answer" => "Paris"})

    assert Imp.Prediction.to_map(prediction) == %{"answer" => "Paris"}
    assert Imp.Prediction.get(prediction, :answer) == "Paris"

    prediction = Imp.Prediction.put(prediction, :answer, "Lyon")
    assert Imp.Prediction.to_map(prediction) == %{"answer" => "Lyon"}
  end

  test "atom keys stay atoms" do
    assert Imp.Example.to_map(Imp.Example.new(question: "q")) == %{question: "q"}
    assert Imp.Prediction.to_map(Imp.Prediction.new(answer: "a")) == %{answer: "a"}
  end
end
