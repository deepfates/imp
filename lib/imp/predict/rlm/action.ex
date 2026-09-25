defmodule Imp.Predict.RLM.Action do
  @moduledoc false

  def decode(text) when is_binary(text) do
    text = String.trim(text)

    case json_payload(text) do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, action} when is_map(action) -> {:ok, action}
          _other -> with {:error, _} <- decode_joined(payload), do: decode_code_fence(text)
        end

      :error ->
        {:error, :invalid_rlm_action_serialization}
    end
  end

  def decode(_value), do: {:error, :invalid_rlm_action_serialization}

  # Models often answer with the code object and a final answer, or a second
  # code object, as several JSON objects one after another. The object that
  # carries code is the action; without one, the first object is.
  defp decode_joined(text) do
    objects =
      text
      |> top_level_objects()
      |> Enum.flat_map(fn object ->
        case Jason.decode(object) do
          {:ok, map} when is_map(map) -> [map]
          _other -> []
        end
      end)

    case {Enum.find(objects, &Map.has_key?(&1, "code")), objects} do
      {nil, [first, _second | _rest]} -> {:ok, first}
      {%{} = code, [_first, _second | _rest]} -> {:ok, code}
      _one_or_none -> {:error, :invalid_rlm_action_serialization}
    end
  end

  # The text of each top-level `{...}` in `text`, braces inside strings
  # ignored.
  defp top_level_objects(text) do
    text
    |> scan(0, 0, false, false, nil, [])
    |> Enum.map(fn {start, length} -> binary_part(text, start, length) end)
  end

  defp scan(<<>>, _index, _depth, _string, _escape, _start, found), do: Enum.reverse(found)

  defp scan(<<char, rest::binary>>, index, depth, true, escape, start, found) do
    cond do
      escape -> scan(rest, index + 1, depth, true, false, start, found)
      char == ?\\ -> scan(rest, index + 1, depth, true, true, start, found)
      char == ?" -> scan(rest, index + 1, depth, false, false, start, found)
      true -> scan(rest, index + 1, depth, true, false, start, found)
    end
  end

  defp scan(<<char, rest::binary>>, index, depth, false, _escape, start, found) do
    case char do
      ?" when depth > 0 ->
        scan(rest, index + 1, depth, true, false, start, found)

      ?{ ->
        scan(
          rest,
          index + 1,
          depth + 1,
          false,
          false,
          if(depth == 0, do: index, else: start),
          found
        )

      ?} when depth == 1 ->
        object = {start, index - start + 1}
        scan(rest, index + 1, 0, false, false, nil, [object | found])

      ?} when depth > 1 ->
        scan(rest, index + 1, depth - 1, false, false, start, found)

      _other ->
        scan(rest, index + 1, depth, false, false, start, found)
    end
  end

  defp json_payload("```json\n" <> rest) do
    case strip_closing_fence(rest) do
      ^rest -> :error
      payload -> {:ok, payload}
    end
  end

  defp json_payload(text), do: {:ok, text}

  defp decode_code_fence("```elixir\n" <> rest), do: code_action(rest)
  defp decode_code_fence("```exs\n" <> rest), do: code_action(rest)
  defp decode_code_fence(_text), do: {:error, :invalid_rlm_action_serialization}

  defp code_action(rest) do
    case strip_closing_fence(rest) do
      code when is_binary(code) and code != rest and code != "" ->
        {:ok, %{"reasoning" => "", "code" => code}}

      _other ->
        {:error, :invalid_rlm_action_serialization}
    end
  end

  defp strip_closing_fence(rest) do
    if String.ends_with?(rest, "\n```") do
      rest
      |> binary_part(0, byte_size(rest) - byte_size("\n```"))
      |> String.trim()
    else
      rest
    end
  end
end
