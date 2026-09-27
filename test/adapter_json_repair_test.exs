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

    # Each expected value is what Python's `ast.literal_eval` returns for the
    # same string literal (Python 3.12).
    test "read escapes as Python's literal_eval does" do
      for {body, expected} <- [
            {"caf#{@b}xe9", "café"},
            {"it#{@b}'s #{@b}\"x#{@b}\" #{@b}#{@b} end#{@b}n", "it's \"x\" \\ end\n"},
            {"#{@b}d+", "\\d+"},
            {"C:#{@b}path", "C:\\path"},
            {"#{@b}q", "\\q"},
            {"a#{@b}/b", "a\\/b"},
            {"#{@b}a#{@b}v#{@b}0", <<7, 11, 0>>},
            {"#{@b}7", <<7>>},
            {"#{@b}101#{@b}x41#{@b}u0041", "AAA"},
            {"#{@b}1234", "S4"},
            {"a#{@b}\nb", "ab"},
            {"a#{@b}\r\nb", "ab"}
          ] do
        assert JSONRepair.decode("{'answer': '#{body}'}") == {:ok, %{"answer" => expected}}, body
      end
    end

    # Python decodes `\N{name}` by the Unicode name table, which OTP does not
    # have; `json_repair`, the first rung of DSPy's ladder, keeps it as written.
    test "keep \\N{name} as written" do
      body = "#{@b}N{LATIN SMALL LETTER E WITH ACUTE}"
      assert JSONRepair.decode("{'answer': '#{body}'}") == {:ok, %{"answer" => body}}
    end

    test "fail where Python's literal has a syntax error, or on a lone surrogate" do
      for body <- [
            "#{@b}u00g9",
            "#{@b}u12",
            "#{@b}x4",
            "#{@b}U0001f6",
            "#{@b}U00110000",
            "#{@b}ud83d alone",
            "#{@b}ude00",
            "#{@b}ud83d#{@b}u0041"
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
               Imp.Adapter.JSON.parse(signature, "{'answer': 'a#{@b}x4'}", [])
    end
  end
end
