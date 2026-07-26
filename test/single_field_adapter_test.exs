defmodule Imp.SingleFieldAdapterTest do
  use ExUnit.Case, async: true

  test "ordinary enum classifier renders a concise contract and parses only an exact value" do
    signature =
      Imp.signature(
        "utterance -> route: enum[R17,R42,R68,R93]",
        "Classify the customer request."
      )

    assert [
             %{role: :system, content: system},
             %{role: :user, content: "utterance: unfamiliar card payment"}
           ] =
             Imp.Adapter.SingleField.format(signature, %{utterance: "unfamiliar card payment"},
               demos: []
             )

    assert system =~ "Output value: route (Literal['R17', 'R42', 'R68', 'R93'])"
    assert system =~ "Return only the value for route"
    refute system =~ "[[ ##"

    assert {:ok, prediction} = Imp.Adapter.SingleField.parse(signature, "  R42\n", [])
    assert Imp.get(prediction, :route) == "R42"

    for malformed <- ["[R42]", "The answer is R42", ~s("R42"), ""] do
      assert {:error, _reason} = Imp.Adapter.SingleField.parse(signature, malformed, [])
    end
  end

  test "complete demonstrations use raw assistant values and partial demos fail loudly" do
    signature = Imp.signature("text -> sentiment: enum[positive,negative]", "Classify sentiment.")

    assert [
             %{role: :system},
             %{role: :user, content: "text: excellent"},
             %{role: :assistant, content: "positive"},
             %{role: :user, content: "text: awful"}
           ] =
             Imp.Adapter.SingleField.format(signature, %{text: "awful"},
               demos: [%{text: "excellent", sentiment: "positive"}]
             )

    assert_raise ArgumentError, ~r/demonstrations must be complete.*sentiment/s, fn ->
      Imp.Adapter.SingleField.format(signature, %{text: "awful"}, demos: [%{text: "excellent"}])
    end
  end

  test "multi-output programs are rejected before generation" do
    signature = Imp.signature("question -> answer, confidence: number")

    assert_raise ArgumentError, ~r/requires exactly one output field/, fn ->
      Imp.Adapter.SingleField.format(signature, %{question: "q"}, [])
    end

    assert_raise ArgumentError, ~r/requires exactly one output field/, fn ->
      Imp.Adapter.SingleField.parse(signature, "a", [])
    end
  end

  test "adapter survives the public save/load boundary" do
    path =
      Path.join(System.tmp_dir!(), "imp-single-field-#{System.unique_integer([:positive])}.json")

    program =
      Imp.predict("utterance -> route: enum[R17,R42]", adapter: Imp.Adapter.SingleField)

    on_exit(fn -> File.rm(path) end)

    assert :ok = Imp.save!(program, path)
    loaded = Imp.load!(path)
    assert loaded.adapter == Imp.Adapter.SingleField

    assert [_, %{role: :user, content: "utterance: pending"}] =
             Imp.Adapter.SingleField.format(loaded.signature, %{utterance: "pending"}, [])
  end
end
