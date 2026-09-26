defmodule SignatureRepeatedNamesTest do
  use ExUnit.Case, async: true

  # A field name appears once in a signature. A repeated name would make one
  # field shadow the other in prompts and parses, so every form refuses it and
  # names it.

  test "the string form refuses a repeated name on either side, or across the arrow" do
    for spec <- ["q -> a, a", "q, q -> a", "a -> a", "q -> answer: str, answer: int"] do
      error = assert_raise Imp.Signature.ParseError, fn -> Imp.signature(spec) end
      assert error.message =~ ~r/'(a|q|answer)'/
    end
  end

  test "the map form refuses a repeated name, comparing names by text" do
    for attrs <- [
          %{inputs: [:q], outputs: [:a, :a]},
          %{inputs: [:q, "q"], outputs: [:a]},
          %{inputs: [:a], outputs: ["a"]}
        ] do
      error = assert_raise ArgumentError, fn -> Imp.signature(attrs) end
      assert error.message =~ "repeated"
    end
  end

  test "extending a signature refuses a name it already has" do
    signature = Imp.signature("q -> a")

    assert_raise ArgumentError, ~r/repeated/, fn ->
      Imp.Signature.extend(signature, :a, :output)
    end

    assert_raise ArgumentError, ~r/repeated/, fn ->
      Imp.Signature.extend(signature, :q, :output)
    end
  end
end
