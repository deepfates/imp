defmodule DSEx.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This adapter accepts map outputs directly and parses provider JSON with Jason.

  Use this adapter when a field is required, typed, constrained, or consumed by
  application code that should not guess its way through prose.

  ## Example

      iex> signature =
      ...>   DSEx.signature(
      ...>     "text -> sentiment: enum[positive,negative], confidence: number",
      ...>     "Classify the text."
      ...>   )
      iex> program = DSEx.predict(signature, adapter: DSEx.Adapter.JSON)
      iex> program.adapter
      DSEx.Adapter.JSON
      iex> {:ok, prediction} =
      ...>   DSEx.Adapter.JSON.parse(signature, ~s({"sentiment":"positive","confidence":0.9}), [])
      iex> {DSEx.get(prediction, :sentiment), DSEx.get(prediction, :confidence)}
      {"positive", 0.9}

  By default the adapter requests provider JSON object mode when the LM client
  supports response-format options. Pass `config: [native_json_schema: true]`
  to request native JSON Schema mode through providers that support it.

  Parse failures return structured retry feedback through
  `DSEx.AdapterParseError`, so callers and retry loops can tell the model what
  violated the schema.
  """

  @behaviour DSEx.Adapter

  @lm_option_schema [
    native_json_schema: [type: :boolean, default: false],
    response_format: [type: :any]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_opts!(opts, "#{inspect(__MODULE__)}.format/3")

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
    opts = validate_lm_opts!(opts, "#{inspect(__MODULE__)}.lm_opts/2")

    cond do
      opts[:native_json_schema] ->
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
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")

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

  defp validate_lm_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(@lm_option_schema))
      |> DSEx.Options.validate!(@lm_option_schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_lm_opts!(opts, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end
