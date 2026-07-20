defmodule Imp.Adapter.JSONRepair do
  @moduledoc false

  # DSPy repairs model output that is almost-JSON before validating it:
  # `parse_value` (dspy/adapters/utils.py) runs `json_repair.loads(value)` and
  # falls back to `ast.literal_eval`, and `JSONAdapter.parse`
  # (dspy/adapters/json_adapter.py) runs `json_repair.loads(completion)` and,
  # when that yields no object, extracts the first balanced `{...}` block and
  # repairs that. This module is the Elixir port of that repair ladder for the
  # spellings those paths accept in practice (dee-16qm, closes dee-q2w2):
  #
  #   * strict JSON first (Jason);
  #   * then Python-literal forms: single-quoted strings, `True`/`False`/`None`,
  #     nested dicts/lists, trailing commas.
  #
  # It is NOT a general Python parser: anything outside those forms is a loud
  # `:error`, so schema validation reports the honest failure instead of a
  # silent guess.

  @doc """
  Decodes `binary` as strict JSON, then as a repaired Python-ish literal.

  Returns `{:ok, term}` or `:error`.
  """
  def decode(binary) when is_binary(binary) do
    trimmed = String.trim(binary)

    case Jason.decode(trimmed) do
      {:ok, term} -> {:ok, term}
      {:error, _reason} -> literal_decode(trimmed)
    end
  end

  @doc """
  Decodes a completion into a JSON OBJECT the way DSPy `JSONAdapter.parse`
  does: repair-decode the whole completion; if that is not an object, find the
  first balanced `{...}` block and repair-decode that.

  Returns `{:ok, map}` or `:error`.
  """
  def decode_object(binary) when is_binary(binary) do
    case decode(binary) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      _other ->
        with {:ok, block} <- find_object(binary),
             {:ok, map} when is_map(map) <- decode(block) do
          {:ok, map}
        else
          _no_object -> :error
        end
    end
  end

  # First balanced `{...}` block (string-aware), mirroring upstream's recursive
  # regex `\{(?:[^{}]|(?R))*\}` over the completion.
  defp find_object(binary) do
    case :binary.match(binary, "{") do
      :nomatch -> :error
      {start, _len} -> balanced_slice(binary, start)
    end
  end

  defp balanced_slice(binary, start) do
    scan_balanced(binary, start, start, 0, nil)
  end

  # Walk bytes from `index`, tracking brace depth and quote state; when depth
  # returns to zero the block is complete.
  defp scan_balanced(binary, start, index, depth, quote_char) do
    if index >= byte_size(binary) do
      :error
    else
      char = :binary.at(binary, index)

      cond do
        # Inside a string: honor escapes, close on the matching quote.
        quote_char != nil ->
          cond do
            char == ?\\ -> scan_balanced(binary, start, index + 2, depth, quote_char)
            char == quote_char -> scan_balanced(binary, start, index + 1, depth, nil)
            true -> scan_balanced(binary, start, index + 1, depth, quote_char)
          end

        char in [?", ?'] ->
          scan_balanced(binary, start, index + 1, depth, char)

        char == ?{ ->
          scan_balanced(binary, start, index + 1, depth + 1, nil)

        char == ?} ->
          if depth == 1 do
            {:ok, binary_part(binary, start, index - start + 1)}
          else
            scan_balanced(binary, start, index + 1, depth - 1, nil)
          end

        true ->
          scan_balanced(binary, start, index + 1, depth, quote_char)
      end
    end
  end

  # ------------------------------------------------------------------
  # Tolerant literal parser (recursive descent). Accepts JSON plus the Python
  # spellings: 'single quotes', True/False/None, trailing commas.

  defp literal_decode(binary) do
    with {:ok, term, rest} <- parse_term(skip_ws(binary)),
         "" <- skip_ws(rest) do
      {:ok, term}
    else
      _other -> :error
    end
  end

  defp parse_term(<<"{", rest::binary>>), do: parse_object(skip_ws(rest), %{})
  defp parse_term(<<"[", rest::binary>>), do: parse_array(skip_ws(rest), [])
  defp parse_term(<<?", _::binary>> = binary), do: parse_string(binary)
  defp parse_term(<<?', _::binary>> = binary), do: parse_string(binary)
  defp parse_term(<<"True", rest::binary>>), do: {:ok, true, rest}
  defp parse_term(<<"False", rest::binary>>), do: {:ok, false, rest}
  defp parse_term(<<"None", rest::binary>>), do: {:ok, nil, rest}
  defp parse_term(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp parse_term(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp parse_term(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp parse_term(binary), do: parse_number(binary)

  defp parse_object(<<"}", rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_object(binary, acc) do
    with {:ok, key, rest} <- parse_string(binary),
         <<":", rest::binary>> <- skip_ws(rest),
         {:ok, value, rest} <- parse_term(skip_ws(rest)) do
      acc = Map.put(acc, key, value)

      case skip_ws(rest) do
        <<",", rest::binary>> -> parse_object(skip_ws(rest), acc)
        <<"}", rest::binary>> -> {:ok, acc, rest}
        _other -> :error
      end
    else
      _other -> :error
    end
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(binary, acc) do
    with {:ok, value, rest} <- parse_term(binary) do
      case skip_ws(rest) do
        <<",", rest::binary>> -> parse_array(skip_ws(rest), [value | acc])
        <<"]", rest::binary>> -> {:ok, Enum.reverse([value | acc]), rest}
        _other -> :error
      end
    end
  end

  defp parse_string(<<quote, rest::binary>>) when quote in [?", ?'] do
    parse_string_body(rest, quote, [])
  end

  defp parse_string(_binary), do: :error

  defp parse_string_body(<<>>, _quote, _acc), do: :error

  defp parse_string_body(<<?\\, escaped, rest::binary>>, quote, acc) do
    resolved =
      case escaped do
        ?n -> ?\n
        ?t -> ?\t
        ?r -> ?\r
        ?b -> ?\b
        ?f -> ?\f
        other -> other
      end

    parse_string_body(rest, quote, [resolved | acc])
  end

  defp parse_string_body(<<char, rest::binary>>, quote, acc) do
    if char == quote do
      {:ok, acc |> Enum.reverse() |> :erlang.list_to_binary(), rest}
    else
      parse_string_body(rest, quote, [char | acc])
    end
  end

  @number_pattern ~r/^-?\d+(\.\d+)?([eE][+-]?\d+)?/

  defp parse_number(binary) do
    case Regex.run(@number_pattern, binary) do
      [match | _groups] ->
        rest = binary_part(binary, byte_size(match), byte_size(binary) - byte_size(match))

        if String.contains?(match, ".") or String.contains?(match, "e") or
             String.contains?(match, "E") do
          {:ok, String.to_float(normalize_float(match)), rest}
        else
          {:ok, String.to_integer(match), rest}
        end

      nil ->
        :error
    end
  end

  # String.to_float requires a leading digit and a dot ("1e3" and ".5" are not
  # accepted); normalize exponent-only floats to a parseable spelling.
  defp normalize_float(match) do
    if String.contains?(match, "."), do: match, else: String.replace(match, ~r/[eE]/, ".0e")
  end

  defp skip_ws(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(binary), do: binary
end
