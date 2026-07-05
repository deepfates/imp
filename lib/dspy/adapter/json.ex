defmodule DSPy.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This adapter accepts map outputs directly and parses provider JSON with Jason.
  """

  @behaviour DSPy.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = DSPy.Adapter.Chat.format(signature, inputs, opts)
    schema = signature.outputs |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")
    [%{role: :system, content: "Return a JSON object with keys: #{schema}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_map(raw),
    do: DSPy.Adapter.Chat.parse(signature, raw, opts)

  def parse(signature, raw, opts) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(extract_json(raw)),
         true <- is_map(decoded),
         {:ok, prediction} <- DSPy.Adapter.Chat.parse(signature, decoded, opts),
         :ok <- DSPy.Schema.validate_fields(signature.outputs, DSPy.Prediction.to_map(prediction)) do
      {:ok, prediction}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         %DSPy.AdapterParseError{message: DSPy.Schema.retry_feedback(errors), reason: raw}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        DSPy.Adapter.Chat.parse(signature, raw, opts)
    end
  end

  def parse(signature, raw, opts), do: DSPy.Adapter.Chat.parse(signature, raw, opts)

  defp extract_json(raw) do
    trimmed = String.trim(raw)

    trimmed
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end
end
