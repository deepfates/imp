defmodule DSEx.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This adapter accepts map outputs directly and parses provider JSON with Jason.
  """

  @behaviour DSEx.Adapter

  @impl true
  def format(signature, inputs, opts) do
    messages =
      DSEx.Adapter.Chat.format(signature, inputs, Keyword.put(opts, :response_instruction, false))

    schema = signature.outputs |> Enum.map(&to_string(&1.name)) |> Enum.join(", ")
    field_contract = output_contract(signature.outputs)

    json_message = %{
      role: :system,
      content:
        "Return only a JSON object with keys: #{schema}. Each value must satisfy the task instruction and its field contract. #{field_contract} Do not include extra explanation or unrelated detail outside those fields."
    }

    [system | rest] = messages
    [system, json_message | rest]
  end

  def lm_opts(signature, opts) do
    cond do
      Keyword.get(opts, :native_json_schema) ->
        [
          response_format: %{
            type: "json_schema",
            json_schema: %{name: "dsex_output", schema: DSEx.Signature.json_schema(signature)}
          }
        ]

      Keyword.get(opts, :response_format) ->
        []

      true ->
        [response_format: %{type: "json_object"}]
    end
  end

  @impl true
  def parse(signature, raw, opts) when is_map(raw),
    do: DSEx.Adapter.Chat.parse(signature, raw, opts)

  def parse(signature, raw, opts) when is_binary(raw) do
    with {:ok, decoded} <- Jason.decode(extract_json(raw)),
         true <- is_map(decoded),
         {:ok, prediction} <- DSEx.Adapter.Chat.parse(signature, decoded, opts),
         :ok <-
           DSEx.Schema.validate_fields(
             signature.outputs,
             DSEx.Prediction.to_map(prediction)
           ) do
      {:ok, prediction}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         %DSEx.AdapterParseError{
           message: DSEx.Schema.retry_feedback(errors),
           reason: raw
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        DSEx.Adapter.Chat.parse(signature, raw, opts)
    end
  end

  def parse(signature, raw, opts), do: DSEx.Adapter.Chat.parse(signature, raw, opts)

  defp extract_json(raw) do
    trimmed = String.trim(raw)

    trimmed
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp output_contract(fields) do
    fields
    |> Enum.map(fn field ->
      desc = field.desc || default_field_desc(field.name)
      "#{field.name}: #{desc}"
    end)
    |> Enum.join("; ")
  end

  defp default_field_desc(:reasoning), do: "show the reasoning needed to derive the answer"
  defp default_field_desc(_name), do: "answer according to the task instruction"
end
