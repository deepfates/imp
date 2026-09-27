defmodule AdapterJSONRepairTest do
  use ExUnit.Case, async: true

  # A single-quoted completion is repaired the way DSPy repairs it: DSPy runs
  # `json_repair` first, and it returns a value for every escape below, so
  # that value is the answer. The expected values here are what DSPy's
  # `JSONAdapter.parse` returns for `{'answer': '<body>'}`;
  # `DSPyJSONAdapterStringParseTest` recomputes them from the pinned DSPy and
  # fails if one drifts. Where Imp cannot give DSPy's value, the row says why,
  # and Imp fails rather than return a different one.

  @b "\\"

  @doc false
  def rows do
    b = @b

    [
      {"caf#{b}u00e9", {:ok, "café"}},
      {"#{b}U0001f600", {:ok, "#{b}U0001f600"}},
      {"caf#{b}xe9", {:ok, "café"}},
      {"café — 東京 🎉", {:ok, "café — 東京 🎉"}},
      {"it#{b}'s #{b}\"x#{b}\" #{b}#{b} end#{b}n", {:ok, "it's \"x\" \\ end"}},
      {"#{b}t|#{b}r|#{b}b|#{b}f", {:ok, "\t|\r|\b|#{b}f"}},
      {"#{b}d+", {:ok, "#{b}d+"}},
      {"C:#{b}path", {:ok, "C:#{b}path"}},
      {"#{b}q", {:ok, "#{b}q"}},
      {"a#{b}/b", {:ok, "a#{b}/b"}},
      {"#{b}a", {:ok, "#{b}a"}},
      {"#{b}v", {:ok, "#{b}v"}},
      {"#{b}0", {:ok, "#{b}0"}},
      {"#{b}7", {:ok, "#{b}7"}},
      {"#{b}101", {:ok, "#{b}101"}},
      {"#{b}N{LATIN SMALL LETTER E WITH ACUTE}", {:ok, "#{b}N{LATIN SMALL LETTER E WITH ACUTE}"}},
      {"a#{b}\nb", {:ok, "a#{b}\nb"}},
      {"a#{b}\r\nb", {:ok, "a#{b}\r\nb"}},
      {"a#{b}#{b}#{b}#{b}b", {:ok, "a#{b}b"}},
      {"#{b}u00g9", {:ok, "#{b}u00g9"}},
      {"#{b}u12", {:ok, "#{b}u12"}},
      {"#{b}x4", {:ok, "#{b}x4"}},
      {"#{b}U0001f6", {:ok, "#{b}U0001f6"}},
      {"#{b}U00110000", {:ok, "#{b}U00110000"}},
      # DSPy's value is two UTF-16 surrogate code units, which an Elixir string
      # cannot hold; Imp returns the one character they spell.
      {"#{b}ud83d#{b}ude00", {:unmatched, {:ok, "😀"}, [0xD83D, 0xDE00]}},
      # DSPy keeps a surrogate that is not half of a pair as a lone code unit,
      # which an Elixir string cannot hold; Imp fails.
      {"#{b}ud83d alone", {:unmatched, :error, [0xD83D | ~c" alone"]}},
      {"#{b}ude00", {:unmatched, :error, [0xDE00]}},
      {"#{b}ud83d#{b}u0041", {:unmatched, :error, [0xD83D, ?A]}},
      # `json_repair` reads the closing quote after `\\` as part of the string
      # and then recovers the string at `}`; this parser does not recover a
      # string whose closing quote it consumed, and fails.
      {"a#{b}#{b}", {:unmatched, :error, [?a, ?']}}
    ]
  end

  test "a single-quoted string decodes to what DSPy parses" do
    for {body, expected} <- rows() do
      imp = Imp.Adapter.JSONRepair.decode("{'answer': '#{body}'}")

      case expected do
        {:ok, answer} -> assert imp == {:ok, %{"answer" => answer}}, inspect(body)
        {:unmatched, {:ok, answer}, _dspy} -> assert imp == {:ok, %{"answer" => answer}}
        {:unmatched, :error, _dspy} -> assert imp == :error, inspect(body)
      end
    end
  end

  test "Imp.Adapter.JSON.parse returns the same answers" do
    signature = Imp.signature("question -> answer")

    for {body, expected} <- rows() do
      result = Imp.Adapter.JSON.parse(signature, "Here: {'answer': '#{body}'}", [])

      case expected do
        {:ok, answer} ->
          assert {:ok, prediction} = result, inspect(body)
          assert Imp.get(prediction, :answer) == answer, inspect(body)

        {:unmatched, {:ok, answer}, _dspy} ->
          assert {:ok, prediction} = result
          assert Imp.get(prediction, :answer) == answer

        {:unmatched, :error, _dspy} ->
          assert {:error, %Imp.AdapterParseError{kind: :malformed}} = result, inspect(body)
      end
    end
  end
end

defmodule DSPyJSONAdapterStringParseTest do
  use ExUnit.Case, async: true

  @moduletag :evidence_infrastructure
  @python "tmp/dspy-current-venv/bin/python"
  @runner "test/support/dspy_json_adapter_string_parse.py"

  test "the repair table is what the pinned DSPy's JSONAdapter.parse returns" do
    unless File.exists?(@python) do
      flunk("run scripts/setup_reference_test_env.sh")
    end

    rows = AdapterJSONRepairTest.rows()

    input =
      Path.join(
        System.tmp_dir!(),
        "imp-json-repair-rows-#{System.unique_integer([:positive])}.json"
      )

    File.write!(input, Jason.encode!(Enum.map(rows, &elem(&1, 0))))

    {output, 0} =
      System.cmd("sh", ["-c", "#{Path.expand(@python)} #{Path.expand(@runner)} < #{input}"])

    File.rm!(input)
    upstream = Jason.decode!(output)
    assert upstream["dspy_version"] == "3.3.1"
    assert upstream["json_repair_version"] == "0.61.4"

    for {{body, expected}, result} <- Enum.zip(rows, upstream["rows"]) do
      assert %{"codepoints" => dspy} = result, inspect(body)

      case expected do
        {:ok, answer} -> assert dspy == String.to_charlist(answer), inspect(body)
        {:unmatched, _imp, recorded} -> assert dspy == recorded, inspect(body)
      end
    end

    assert length(upstream["rows"]) == length(rows)
  end
end
