defmodule Imp.Predict.RLM.Action do
  @moduledoc false

  def decode(text) when is_binary(text) do
    text = String.trim(text)

    case json_payload(text) do
      {:ok, payload} ->
        case Jason.decode(payload) do
          {:ok, action} when is_map(action) -> {:ok, action}
          _other -> decode_code_fence(text)
        end

      :error ->
        {:error, :invalid_rlm_action_serialization}
    end
  end

  def decode(_value), do: {:error, :invalid_rlm_action_serialization}

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
