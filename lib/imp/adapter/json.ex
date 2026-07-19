defmodule Imp.Adapter.JSON do
  @moduledoc """
  JSON-oriented adapter.

  This adapter accepts map outputs directly and parses provider JSON with Jason.

  Use this adapter when a field is required, typed, constrained, or consumed by
  application code that should not guess its way through prose.

  ## Example

      iex> signature =
      ...>   Imp.signature(
      ...>     "text -> sentiment: enum[positive,negative], confidence: number",
      ...>     "Classify the text."
      ...>   )
      iex> program = Imp.predict(signature, adapter: Imp.Adapter.JSON)
      iex> program.adapter
      Imp.Adapter.JSON
      iex> {:ok, prediction} =
      ...>   Imp.Adapter.JSON.parse(signature, ~s({"sentiment":"positive","confidence":0.9}), [])
      iex> {Imp.get(prediction, :sentiment), Imp.get(prediction, :confidence)}
      {"positive", 0.9}

  By default the adapter requests provider JSON object mode when the LM client
  supports response-format options. Pass `config: [native_json_schema: true]`
  to request native JSON Schema mode through providers that support it.

  Parse failures return structured retry feedback through
  `Imp.AdapterParseError`, so callers and retry loops can tell the model what
  violated the schema.
  """

  @behaviour Imp.Adapter

  @lm_option_schema [
    native_json_schema: [type: :boolean, default: false],
    response_format: [type: {:custom, __MODULE__, :validate_response_format, []}]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_opts!(opts, "#{inspect(__MODULE__)}.format/3")

    # Reuse Chat's structure for input rendering, demos, and history, but with
    # Chat's own response instruction suppressed — JSONAdapter substitutes its
    # own system message and its own trailing output requirements.
    #
    # DSPy's JSONAdapter overrides `format_assistant_message_content` so demo /
    # history ASSISTANT turns emit a pretty-printed JSON object, NOT the chat
    # `[[ ## field ## ]]` markers. We inject that assistant renderer into Chat's
    # message assembly (dee-0bwu) instead of delegating Chat.render_outputs.
    format_opts =
      opts
      |> Keyword.put(:response_instruction, false)
      |> Keyword.put(:output_renderer, &render_assistant_json/3)

    messages = Imp.Adapter.Chat.format(signature, inputs, format_opts)

    [_chat_system | rest] = messages
    system = %{role: :system, content: render_system(signature)}

    [system | append_output_requirements(rest, signature)]
  end

  # DSPy's JSONAdapter appends `user_message_output_requirements` to the final
  # (main-request) user message. In Chat's message list that is always the last
  # message, so we append the JSON tail there.
  defp append_output_requirements(messages, signature) do
    tail = "\n\n" <> user_message_output_requirements(signature)
    {init, [last]} = Enum.split(messages, -1)
    init ++ [Map.update!(last, :content, &append_text(&1, tail))]
  end

  defp append_text(content, suffix) when is_binary(content), do: content <> suffix
  defp append_text(content, suffix) when is_list(content), do: content ++ [suffix]

  # ------------------------------------------------------------------
  # DSPy JSONAdapter system message: format_field_description (inherited from
  # ChatAdapter) + JSONAdapter.format_field_structure + format_task_description.
  # ------------------------------------------------------------------
  defp render_system(signature) do
    field_description(signature) <>
      "\n" <> field_structure(signature) <> "\n" <> task_description(signature)
  end

  # ChatAdapter.format_field_description / utils.get_field_description_string.
  defp field_description(signature) do
    "Your input fields are:\n" <>
      field_desc_block(signature.inputs) <>
      "\nYour output fields are:\n" <> field_desc_block(signature.outputs)
  end

  defp field_desc_block(fields) do
    fields
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {field, index} ->
      "#{index}. `#{field.name}` (#{field_annotation_name(field)}): #{field_desc(field)}"
    end)
    |> String.trim()
  end

  # DSPy get_field_description_string (utils.py:230) renders a description equal
  # to the "${name}" placeholder (the ChainOfThought reasoning sentinel) as
  # empty. chat.ex already mirrors this; json.ex must too (dee-cidk).
  defp field_desc(field) do
    if field.desc == "${#{field.name}}", do: "", else: to_string(field.desc || "")
  end

  # JSONAdapter.format_field_structure.
  defp field_structure(signature) do
    [
      "All interactions will be structured in the following way, with the appropriate values filled in.",
      "Inputs will have the following structure:",
      input_structure(signature.inputs),
      "Outputs will be a JSON object with the following fields.",
      output_structure(signature.outputs)
    ]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  # Inputs rendered with role="user": `[[ ## name ## ]]\n{translate_field_type}`.
  defp input_structure(inputs) do
    inputs
    |> Enum.map_join("\n\n", fn field ->
      "[[ ## #{field.name} ## ]]\n" <> translate_field_type(field, :input)
    end)
    |> String.trim()
  end

  # Outputs rendered with role="assistant": a pretty-printed JSON object whose
  # values are the `translate_field_type` templates (with type notes inline).
  defp output_structure(outputs) do
    outputs
    |> Enum.map(fn field -> {to_string(field.name), translate_field_type(field, :output)} end)
    |> pretty_json_object()
  end

  # utils.translate_field_type: input fields (and str/reasoning) carry no note;
  # typed output fields carry an 8-space-indented note inside the value.
  defp translate_field_type(field, :input), do: "{#{field.name}}"

  defp translate_field_type(field, :output) do
    case output_note_desc(field) do
      nil ->
        "{#{field.name}}"

      note ->
        "{#{field.name}}" <> String.duplicate(" ", 8) <> "# note: the value you produce " <> note
    end
  end

  # Composite output fields (enum->Literal, array->list, object->dict) note first
  # via CompositeType (dee-9ttv); scalars keep their existing type_note clauses.
  defp output_note_desc(field),
    do: Imp.Adapter.CompositeType.note_desc(field) || type_note(field.type)

  defp type_note(:string), do: nil
  defp type_note(:integer), do: "must be a single int value"
  defp type_note(:float), do: "must be a single float value"
  defp type_note(:boolean), do: "must be True or False"
  # `:number` has no native DSPy counterpart; treat like float for the note.
  defp type_note(:number), do: "must be a single float value"
  defp type_note(_type), do: nil

  # ChatAdapter.format_task_description.
  defp task_description(signature) do
    "In adhering to this structure, your objective is: " <>
      Imp.Adapter.Instructions.objective_text(signature.instructions)
  end

  # JSONAdapter.user_message_output_requirements.
  defp user_message_output_requirements(signature) do
    fields =
      Enum.map_join(signature.outputs, ", then ", fn field ->
        "`#{field.name}`" <> type_info(field)
      end)

    "Respond with a JSON object in the following order of fields: " <> fields <> "."
  end

  defp type_info(field) do
    case field_annotation_name(field) do
      "str" -> ""
      name -> " (must be formatted as a valid Python #{name})"
    end
  end

  # DSPy annotation name for a field: composite types (Literal/list/dict) resolve
  # through CompositeType; scalars fall back to the plain type-name mapping.
  defp field_annotation_name(field),
    do: Imp.Adapter.CompositeType.annotation_name(field) || annotation_name(field.type)

  # utils.get_annotation_name for the scalar types Imp models.
  defp annotation_name(:string), do: "str"
  defp annotation_name(:integer), do: "int"
  defp annotation_name(:float), do: "float"
  defp annotation_name(:boolean), do: "bool"
  defp annotation_name(:number), do: "float"
  defp annotation_name(type), do: to_string(type)

  # Demo / history ASSISTANT-turn renderer injected into Chat.format.
  # Mirrors DSPy JSONAdapter.format_assistant_message_content:
  #   d = {k.name: outputs.get(k, missing_field_message) for k in output_fields}
  #   json.dumps(serialize_for_json(d), indent=2, ensure_ascii=False)
  # Value resolution (key-presence, present-nil kept) is shared with Chat so the
  # two adapters differ only in serialization: markers here become a JSON object.
  defp render_assistant_json(signature, outputs, missing_field_message) do
    signature
    |> Imp.Adapter.Chat.resolve_demo_outputs(outputs, missing_field_message)
    |> Enum.map(fn {name, value} -> {to_string(name), value} end)
    |> pretty_json_object()
  end

  # Mirror Python `json.dumps(obj, indent=2, ensure_ascii=False)` for an ordered
  # object whose values are JSON scalars (strings for the structure template;
  # strings/bools/nil/numbers for assistant demo turns).
  defp pretty_json_object([]), do: "{}"

  defp pretty_json_object(pairs) do
    body =
      Enum.map_join(pairs, ",\n", fn {key, value} ->
        "  " <> Jason.encode!(key) <> ": " <> Jason.encode!(value)
      end)

    "{\n" <> body <> "\n}"
  end

  def lm_opts(signature, opts) do
    opts = validate_lm_opts!(opts, "#{inspect(__MODULE__)}.lm_opts/2")

    cond do
      opts[:native_json_schema] ->
        [
          response_format: %{
            type: "json_schema",
            json_schema: %{name: "imp_output", schema: Imp.Signature.json_schema(signature)}
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
    do: Imp.Adapter.Chat.parse(signature, raw, opts)

  def parse(signature, raw, opts) when is_binary(raw) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")

    with {:ok, decoded} <- Jason.decode(extract_json(raw)),
         true <- is_map(decoded),
         {:ok, prediction} <- Imp.Adapter.Chat.parse(signature, decoded, opts),
         :ok <-
           Imp.Schema.validate_fields(
             signature.outputs,
             Imp.Prediction.to_map(prediction)
           ) do
      {:ok, prediction}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         %Imp.AdapterParseError{
           message: Imp.Schema.retry_feedback(errors),
           reason: raw
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        Imp.Adapter.Chat.parse(signature, raw, opts)
    end
  end

  def parse(signature, raw, opts), do: Imp.Adapter.Chat.parse(signature, raw, opts)

  @doc false
  def validate_response_format(format) when is_map(format), do: {:ok, format}

  def validate_response_format(format) do
    {:error, "expected a provider response_format map, got: #{inspect(format)}"}
  end

  defp extract_json(raw) do
    trimmed = String.trim(raw)

    trimmed
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp validate_lm_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(@lm_option_schema))
      |> Imp.Options.validate!(@lm_option_schema, context)
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
