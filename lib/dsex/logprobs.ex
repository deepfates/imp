defmodule DSEx.Logprobs do
  @moduledoc """
  Extracts joint token logprob for one enum-constrained JSON field.

  The overlap rule is the exact rule used by `llm-structured-confidence` 0.4.5,
  the extraction authority used by GEPA commit
  `65df4325e3fb4781cf2ab17dd144d6ce2f7b98fe`: token span `[a, b)` contributes
  when `max(field_start, a) < min(field_end, b)`. String quotes are excluded.

  Unlike the upstream helper, an empty overlap is an error. It is never turned
  into joint logprob `0.0` (raw confidence `1.0`), because that would represent
  missing evidence as maximal confidence.
  """

  @epsilon 1.0e-5

  @type alternative :: %{
          token: String.t(),
          logprob: number(),
          raw_confidence: float(),
          resolved_value: String.t() | nil
        }

  @type extraction :: %{
          value: String.t(),
          joint_logprob: float(),
          raw_confidence: float(),
          tokens: [map()],
          top_alternatives: [alternative()]
        }

  @doc "Extracts confidence for a dot-separated JSON field path."
  @spec extract(String.t(), [map()], atom() | String.t(), [String.t()]) ::
          {:ok, extraction()} | {:error, term()}
  def extract(content, logprobs, field_path, enum_values)
      when is_binary(content) and is_list(logprobs) and is_list(enum_values) do
    field_path = to_string(field_path)

    with :ok <- validate_field_path(field_path),
         :ok <- validate_enum(enum_values),
         {:ok, tokens} <- normalize_tokens(logprobs),
         :ok <- tokens_match_content(tokens, content),
         {:ok, spans} <- json_spans(content),
         {:ok, span} <- fetch_span(spans, field_path),
         true <- is_binary(span.value) or {:error, :classification_value_not_string},
         true <- span.value in enum_values or {:error, {:value_outside_enum, span.value}},
         overlapping when overlapping != [] <- overlapping_tokens(tokens, span),
         joint_logprob <- Enum.sum(Enum.map(overlapping, & &1.logprob)) do
      {:ok,
       %{
         value: span.value,
         joint_logprob: joint_logprob * 1.0,
         raw_confidence: :math.exp(joint_logprob),
         tokens: overlapping,
         top_alternatives: top_alternatives(overlapping, enum_values)
       }}
    else
      [] -> {:error, :no_overlapping_logprob_tokens}
      {:error, _reason} = error -> error
      false -> {:error, :invalid_logprob_extraction}
    end
  end

  def extract(_content, _logprobs, _field_path, _enum_values),
    do: {:error, :invalid_logprob_arguments}

  defp validate_field_path(""), do: {:error, :empty_field_path}

  defp validate_field_path(path) do
    if Enum.all?(String.split(path, "."), &valid_path_segment?/1),
      do: :ok,
      else: {:error, :invalid_field_path}
  end

  defp valid_path_segment?(segment),
    do: segment != "" and not String.contains?(segment, ["[", "]"])

  defp validate_enum(values) do
    if values != [] and Enum.all?(values, &is_binary/1) and
         length(Enum.uniq(values)) == length(values),
       do: :ok,
       else: {:error, :invalid_enum_values}
  end

  defp normalize_tokens(logprobs) do
    logprobs
    |> Enum.reduce_while({:ok, {[], 0}}, fn token, {:ok, {tokens, offset}} ->
      with true <- is_map(token),
           text when is_binary(text) <- map_value(token, :token),
           logprob when is_number(logprob) <- map_value(token, :logprob) do
        normalized = %{
          token: text,
          logprob: logprob * 1.0,
          top_logprobs: normalize_top_logprobs(map_value(token, :top_logprobs)),
          char_start: offset,
          char_end: offset + byte_size(text)
        }

        {:cont, {:ok, {[normalized | tokens], normalized.char_end}}}
      else
        _invalid -> {:halt, {:error, :malformed_logprob_token}}
      end
    end)
    |> case do
      {:ok, {tokens, _offset}} -> {:ok, Enum.reverse(tokens)}
      error -> error
    end
  end

  defp normalize_top_logprobs(values) when is_list(values) do
    Enum.flat_map(values, fn alternative ->
      with true <- is_map(alternative),
           token when is_binary(token) <- map_value(alternative, :token),
           logprob when is_number(logprob) <- map_value(alternative, :logprob) do
        [%{token: token, logprob: logprob * 1.0}]
      else
        _invalid -> []
      end
    end)
  end

  defp normalize_top_logprobs(_values), do: []

  defp tokens_match_content(tokens, content) do
    if Enum.map_join(tokens, & &1.token) == content,
      do: :ok,
      else: {:error, :logprob_tokens_do_not_match_content}
  end

  defp overlapping_tokens(tokens, span) do
    Enum.filter(tokens, fn token ->
      max(span.char_start, token.char_start) < min(span.char_end, token.char_end)
    end)
  end

  defp top_alternatives(tokens, enum_values) do
    selected =
      Enum.find(tokens, fn token ->
        abs(token.logprob) > @epsilon and token.top_logprobs != []
      end) || List.first(tokens)

    Enum.map(selected.top_logprobs, fn alternative ->
      %{
        token: alternative.token,
        logprob: alternative.logprob,
        raw_confidence: :math.exp(alternative.logprob),
        resolved_value: resolve_prefix(alternative.token, enum_values)
      }
    end)
  end

  defp resolve_prefix(token, enum_values) do
    case Enum.filter(enum_values, &String.starts_with?(&1, token)) do
      [value] -> value
      _ambiguous_or_missing -> nil
    end
  end

  defp fetch_span(spans, field_path) do
    case Map.fetch(spans, field_path) do
      {:ok, span} -> {:ok, span}
      :error -> {:error, {:field_not_found, field_path}}
    end
  end

  defp json_spans(content) do
    with {:ok, _decoded} <- Jason.decode(content),
         {:ok, _end_pos, spans} <- parse_value(content, skip_ws(content, 0), "", %{}) do
      {:ok, spans}
    else
      _invalid -> {:error, :invalid_json}
    end
  end

  defp parse_value(content, pos, path, spans) do
    case :binary.at(content, pos) do
      ?{ -> parse_object(content, pos + 1, path, spans)
      ?[ -> parse_array(content, pos + 1, path, spans, 0)
      ?" -> parse_string_value(content, pos, path, spans)
      _other -> parse_scalar(content, pos, path, spans)
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp parse_object(content, pos, path, spans) do
    pos = skip_ws(content, pos)

    if :binary.at(content, pos) == ?} do
      {:ok, pos + 1, spans}
    else
      with {:ok, key, key_end} <- parse_json_string(content, pos),
           colon <- skip_ws(content, key_end),
           true <- :binary.at(content, colon) == ?:,
           child_path <- if(path == "", do: key, else: path <> "." <> key),
           {:ok, value_end, spans} <-
             parse_value(content, skip_ws(content, colon + 1), child_path, spans) do
        continue_object(content, skip_ws(content, value_end), path, spans)
      else
        _invalid -> {:error, :invalid_json}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp continue_object(content, pos, path, spans) do
    case :binary.at(content, pos) do
      ?, -> parse_object(content, pos + 1, path, spans)
      ?} -> {:ok, pos + 1, spans}
      _other -> {:error, :invalid_json}
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp parse_array(content, pos, path, spans, index) do
    pos = skip_ws(content, pos)

    if :binary.at(content, pos) == ?] do
      {:ok, pos + 1, spans}
    else
      child_path = path <> "[#{index}]"

      with {:ok, value_end, spans} <- parse_value(content, pos, child_path, spans) do
        case :binary.at(content, skip_ws(content, value_end)) do
          ?, -> parse_array(content, skip_ws(content, value_end) + 1, path, spans, index + 1)
          ?] -> {:ok, skip_ws(content, value_end) + 1, spans}
          _other -> {:error, :invalid_json}
        end
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp parse_string_value(content, pos, path, spans) do
    with {:ok, value, end_pos} <- parse_json_string(content, pos) do
      span = %{value: value, char_start: pos + 1, char_end: end_pos - 1}
      {:ok, end_pos, Map.put(spans, path, span)}
    end
  end

  defp parse_scalar(content, pos, path, spans) do
    end_pos = scalar_end(content, pos)
    raw = binary_part(content, pos, end_pos - pos)

    case Jason.decode(raw) do
      {:ok, value} ->
        span = %{value: value, char_start: pos, char_end: end_pos}
        {:ok, end_pos, Map.put(spans, path, span)}

      _error ->
        {:error, :invalid_json}
    end
  end

  defp parse_json_string(content, pos) do
    with true <- :binary.at(content, pos) == ?",
         {:ok, quote_pos} <- closing_quote(content, pos + 1),
         raw <- binary_part(content, pos, quote_pos - pos + 1),
         {:ok, value} when is_binary(value) <- Jason.decode(raw) do
      {:ok, value, quote_pos + 1}
    else
      _invalid -> {:error, :invalid_json}
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp closing_quote(content, pos) do
    case :binary.at(content, pos) do
      ?" -> {:ok, pos}
      ?\\ -> closing_quote(content, pos + 2)
      _other -> closing_quote(content, pos + 1)
    end
  rescue
    ArgumentError -> {:error, :invalid_json}
  end

  defp scalar_end(content, pos) when pos >= byte_size(content), do: pos

  defp scalar_end(content, pos) do
    if :binary.at(content, pos) in [?,, ?}, ?], ?\s, ?\t, ?\n, ?\r],
      do: pos,
      else: scalar_end(content, pos + 1)
  end

  defp skip_ws(content, pos) when pos >= byte_size(content), do: pos

  defp skip_ws(content, pos) do
    if :binary.at(content, pos) in [?\s, ?\t, ?\n, ?\r],
      do: skip_ws(content, pos + 1),
      else: pos
  end

  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
