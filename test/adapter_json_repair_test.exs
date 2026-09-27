defmodule AdapterJSONRepairTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.JSONRepair

  # The Python-literal path reads single-quoted strings byte by byte. Text that
  # is not ASCII must come out as the same characters, and an escape must come
  # out as the character it names, or the decode must fail: a changed value
  # that reports success is worse than an error.

  @b "\\"

  describe "single-quoted strings" do
    test "keep non-ASCII text byte for byte" do
      assert JSONRepair.decode("{'answer': 'café — 東京 🎉'}") ==
               {:ok, %{"answer" => "café — 東京 🎉"}}
    end

    test "decode \\u escapes to the character they name" do
      assert JSONRepair.decode("{'answer': 'caf#{@b}u00e9'}") == {:ok, %{"answer" => "café"}}
      assert JSONRepair.decode("{'answer': '#{@b}u6771#{@b}u4eac'}") == {:ok, %{"answer" => "東京"}}
    end

    test "decode an emoji written as a surrogate pair, as \\U, or as itself" do
      for spelling <- ["#{@b}ud83d#{@b}ude00", "#{@b}U0001f600", "😀"] do
        assert JSONRepair.decode("{'answer': '#{spelling}!'}") == {:ok, %{"answer" => "😀!"}}
      end
    end

    test "decode Python's \\x escape and the shared single-character escapes" do
      assert JSONRepair.decode("{'answer': 'caf#{@b}xe9'}") == {:ok, %{"answer" => "café"}}

      assert JSONRepair.decode("{'a': 'it#{@b}'s #{@b}\"x#{@b}\" #{@b}#{@b} a#{@b}/b#{@b}n'}") ==
               {:ok, %{"a" => "it's \"x\" \\ a/b\n"}}
    end

    test "fail on an escape they cannot read, never drop its backslash" do
      for body <- [
            "a#{@b}qb",
            "#{@b}u00g9",
            "#{@b}ud83d alone",
            "#{@b}ude00",
            "#{@b}ud83d#{@b}u0041",
            "#{@b}U00110000"
          ] do
        assert JSONRepair.decode("{'answer': '#{body}'}") == :error, body
      end
    end
  end

  describe "Imp.Adapter.JSON.parse" do
    setup do
      %{signature: Imp.signature("question -> answer")}
    end

    test "returns the characters a repaired completion spelled", %{signature: signature} do
      for {completion, answer} <- [
            {"{'answer': 'café'}", "café"},
            {"{'answer': 'caf#{@b}u00e9'}", "café"},
            {"{'answer': '#{@b}ud83d#{@b}ude00'}", "😀"},
            {"Here: {'answer': '#{@b}U0001f389 caf#{@b}u00e9'}", "🎉 café"}
          ] do
        assert {:ok, prediction} = Imp.Adapter.JSON.parse(signature, completion, [])
        assert Imp.get(prediction, :answer) == answer, completion
      end
    end

    test "is a loud error for an escape it cannot read", %{signature: signature} do
      assert {:error, %Imp.AdapterParseError{kind: :malformed}} =
               Imp.Adapter.JSON.parse(signature, "{'answer': 'a#{@b}qb'}", [])
    end
  end
end
