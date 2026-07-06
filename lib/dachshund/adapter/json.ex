defmodule Dachshund.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This adapter accepts map outputs directly and parses provider JSON with Jason.
  """

  @behaviour Dachshund.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages = Dachshund.Adapter.Chat.format(signature, inputs, opts)
    schema = signature.outputs |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")
    [%{role: :system, content: "Return a JSON object with keys: #{schema}"} | messages]
  end

  @impl true
  def parse(signature, raw, opts) when is_map(raw),
    do: Dachshund.Adapter.Chat.parse(signature, raw, opts)

  def parse(signature, raw, opts) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(extract_json(raw)),
         true <- is_map(decoded),
         {:ok, prediction} <- Dachshund.Adapter.Chat.parse(signature, decoded, opts),
         :ok <-
           Dachshund.Schema.validate_fields(
             signature.outputs,
             Dachshund.Prediction.to_map(prediction)
           ) do
      {:ok, prediction}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         %Dachshund.AdapterParseError{
           message: Dachshund.Schema.retry_feedback(errors),
           reason: raw
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        Dachshund.Adapter.Chat.parse(signature, raw, opts)
    end
  end

  def parse(signature, raw, opts), do: Dachshund.Adapter.Chat.parse(signature, raw, opts)

  defp extract_json(raw) do
    trimmed = String.trim(raw)

    trimmed
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end
end
