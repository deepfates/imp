defmodule Imp.Adapter.Instructions do
  @moduledoc false

  # Byte-faithful reproduction of how DSPy 3.2.1 turns a signature's raw
  # instructions into the "objective" line both the ChatAdapter and JSONAdapter
  # render (`format_task_description`).
  #
  # DSPy composes three transforms the previous Imp code skipped (dee-709o):
  #
  #   1. `signature.instructions` = `inspect.cleandoc(__doc__)`
  #      (expand tabs, strip the first line, dedent the rest by their common
  #      indent, drop leading/trailing blank lines).
  #   2. `textwrap.dedent(instructions)` in `format_task_description`
  #      (normalize whitespace-only lines to empty; strip common leading margin).
  #   3. `("\n" + " " * 8).join([""] + instructions.splitlines())`
  #      where `str.splitlines()` splits on the FULL Unicode line-boundary set,
  #      not just `\n`.
  #
  # The old `String.split(instructions, "\n") |> Enum.join("\n        ")` matched
  # only clean single-line ASCII instructions; any indented/multiline/CRLF/exotic
  # instruction diverged. Shared here so chat.ex and json.ex apply it once
  # (retiring the former byte-copy in both).

  @doc """
  The rendered objective body: what follows `... your objective is: ` in both
  adapters' system messages. Reproduces DSPy's cleandoc + dedent + splitlines +
  8-space-indent join over the raw instructions.
  """
  def objective_text(instructions) do
    instructions
    |> to_string()
    |> cleandoc()
    |> dedent()
    |> splitlines()
    |> then(fn lines -> [""] ++ lines end)
    |> Enum.join("\n        ")
  end

  # -- inspect.cleandoc -------------------------------------------------------

  # CPython `inspect.cleandoc`:
  #   lines = doc.expandtabs().split('\n')
  #   margin = min indent over non-blank lines[1:]
  #   lines[0] = lines[0].lstrip()
  #   lines[i>=1] = lines[i][margin:]
  #   drop trailing then leading fully-empty lines
  #   '\n'.join(lines)
  # NOTE cleandoc splits ONLY on '\n' — non-LF Unicode boundaries survive here
  # and are split later by splitlines/1.
  defp cleandoc(doc) do
    lines = doc |> expand_tabs() |> String.split("\n")

    {first, rest} =
      case lines do
        [] -> {nil, []}
        [head | tail] -> {head, tail}
      end

    margin =
      Enum.reduce(rest, :infinity, fn line, acc ->
        content = lstrip_ws(line)

        if content == "" do
          acc
        else
          min(acc, cp_length(line) - cp_length(content))
        end
      end)

    first = if is_nil(first), do: nil, else: lstrip_ws(first)

    rest =
      if margin == :infinity,
        do: rest,
        else: Enum.map(rest, &cp_drop(&1, margin))

    ((first && [first]) || [])
    |> Kernel.++(rest)
    |> drop_trailing_empty()
    |> drop_leading_empty()
    |> Enum.join("\n")
  end

  defp drop_trailing_empty(lines) do
    lines |> Enum.reverse() |> drop_leading_empty() |> Enum.reverse()
  end

  # cleandoc pops only FULLY-empty ("") boundary lines, not whitespace-only ones.
  defp drop_leading_empty(["" | rest]), do: drop_leading_empty(rest)
  defp drop_leading_empty(lines), do: lines

  # -- textwrap.dedent --------------------------------------------------------

  # CPython `textwrap.dedent`:
  #   whitespace-only lines (`^[ \t]+$`) -> ""
  #   margin = longest common leading `[ \t]*` prefix over content-bearing lines
  #   strip that margin from the start of each line
  defp dedent(text) do
    lines = String.split(text, "\n")
    normalized = Enum.map(lines, fn line -> if whitespace_only?(line), do: "", else: line end)

    margin =
      normalized
      |> Enum.reduce(nil, fn line, acc ->
        case leading_ws(line) do
          nil -> acc
          indent -> common_prefix(acc, indent)
        end
      end)

    normalized
    |> Enum.map(fn line -> strip_prefix(line, margin) end)
    |> Enum.join("\n")
  end

  # Leading `[ \t]*` of a line that has a non-`[ \t]` character; nil if the line
  # is empty or all `[ \t]` (those do not constrain the common margin).
  defp leading_ws(line) do
    graphemes = String.graphemes(line)
    ws = Enum.take_while(graphemes, &(&1 in [" ", "\t"]))

    if length(ws) == length(graphemes) do
      # empty or whitespace-only: no content char, does not contribute
      nil
    else
      Enum.join(ws)
    end
  end

  defp whitespace_only?(""), do: false

  defp whitespace_only?(line) do
    line |> String.graphemes() |> Enum.all?(&(&1 in [" ", "\t"]))
  end

  defp common_prefix(nil, indent), do: indent
  defp common_prefix(a, b), do: do_common_prefix(a, b, "")

  defp do_common_prefix(<<c::utf8, a::binary>>, <<c::utf8, b::binary>>, acc),
    do: do_common_prefix(a, b, acc <> <<c::utf8>>)

  defp do_common_prefix(_a, _b, acc), do: acc

  defp strip_prefix(line, nil), do: line
  defp strip_prefix(line, ""), do: line

  defp strip_prefix(line, margin) do
    case String.starts_with?(line, margin) do
      true -> String.replace_prefix(line, margin, "")
      false -> line
    end
  end

  # -- str.splitlines ---------------------------------------------------------

  # Python universal newlines: \n \r \r\n \v \f \x1c \x1d \x1e \x85 U+2028 U+2029.
  @boundaries [0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029]

  @doc false
  def splitlines(str), do: do_splitlines(String.to_charlist(str), [], [])

  # \r\n is a single boundary.
  defp do_splitlines([0x0D, 0x0A | rest], cur, acc),
    do: do_splitlines(rest, [], [emit(cur) | acc])

  defp do_splitlines([c | rest], cur, acc) when c in @boundaries,
    do: do_splitlines(rest, [], [emit(cur) | acc])

  defp do_splitlines([c | rest], cur, acc), do: do_splitlines(rest, [c | cur], acc)

  # End of input: a still-open (non-emitted) line is flushed; a just-closed
  # boundary leaves nothing pending, so no spurious trailing "" is produced.
  defp do_splitlines([], [], acc), do: Enum.reverse(acc)
  defp do_splitlines([], cur, acc), do: Enum.reverse([emit(cur) | acc])

  defp emit(cur), do: cur |> Enum.reverse() |> List.to_string()

  # -- helpers ----------------------------------------------------------------

  # Python str.lstrip() default: strip leading Unicode whitespace.
  defp lstrip_ws(line) do
    line
    |> String.to_charlist()
    |> Enum.drop_while(&python_space?/1)
    |> List.to_string()
  end

  # Codepoints CPython's Py_UNICODE_ISSPACE treats as whitespace.
  @spaces MapSet.new([
            0x09,
            0x0A,
            0x0B,
            0x0C,
            0x0D,
            0x1C,
            0x1D,
            0x1E,
            0x1F,
            0x20,
            0x85,
            0xA0,
            0x1680,
            0x2000,
            0x2001,
            0x2002,
            0x2003,
            0x2004,
            0x2005,
            0x2006,
            0x2007,
            0x2008,
            0x2009,
            0x200A,
            0x2028,
            0x2029,
            0x202F,
            0x205F,
            0x3000
          ])

  defp python_space?(codepoint), do: MapSet.member?(@spaces, codepoint)

  # Python str.expandtabs(8): expand tabs to the next multiple of 8; \n and \r
  # (only) reset the column to 0. Column counts code points.
  defp expand_tabs(str, tabsize \\ 8) do
    str
    |> String.to_charlist()
    |> Enum.reduce({[], 0}, fn
      ?\t, {acc, col} ->
        n = tabsize - rem(col, tabsize)
        {List.duplicate(?\s, n) ++ acc, col + n}

      c, {acc, _col} when c in [?\n, ?\r] ->
        {[c | acc], 0}

      c, {acc, col} ->
        {[c | acc], col + 1}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp cp_length(str), do: str |> String.to_charlist() |> length()

  defp cp_drop(str, n) do
    str |> String.to_charlist() |> Enum.drop(n) |> List.to_string()
  end
end
