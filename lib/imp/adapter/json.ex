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
      "#{index}. `#{field.name}` (#{field_annotation_name(field)}): #{field_desc(field)}" <>
        Imp.Adapter.FieldConstraints.suffix(field)
    end)
    |> String.trim()
  end

  # DSPy get_field_description_string (utils.py:230) renders a description equal
  # to the "${name}" placeholder (the ChainOfThought reasoning sentinel) as
  # empty. chat.ex already mirrors this; json.ex must too (dee-cidk).
  defp field_desc(field) do
    base = if field.desc == "${#{field.name}}", do: "", else: to_string(field.desc || "")

    if code_field?(field) do
      type_description =
        "Type description of #{code_annotation(field)}: " <>
          Imp.Adapter.Types.Code.description(code_language(field))

      case base do
        "" -> "\n    " <> type_description
        _ -> base <> "\n    " <> type_description
      end
    else
      base
    end
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
  defp field_annotation_name(field) do
    if code_field?(field),
      do: code_annotation(field),
      else: Imp.Adapter.CompositeType.annotation_name(field) || annotation_name(field.type)
  end

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
    |> Enum.map(fn {name, value} -> {to_string(name), json_value(value)} end)
    |> pretty_json_object()
  end

  defp json_value(%Imp.Adapter.Types.Code{} = value),
    do: Imp.Adapter.Types.Code.format(value)

  defp json_value(value), do: value

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

  @doc """
  Provider request options for a JSON-adapter call. Faithful to DSPy's
  `JSONAdapter`, which selects `response_format` by the LM's *capability*, not by
  which keys the caller passed (`dspy/adapters/json_adapter.py`
  `_json_adapter_call_common` + `__call__`):

    * LM does NOT accept `response_format` (`"response_format" not in
      lm.supported_params`) -> send NOTHING.
    * LM accepts `response_format` but not structured schema
      (`not lm.supports_response_schema`, or an open-ended `dict` output) ->
      `{"type": "json_object"}`.
    * LM supports structured JSON schema -> a pydantic-shaped `json_schema`
      built from the signature outputs (DSPy's
      `_get_structured_outputs_response_format`, in the litellm wire form).

  `capability` is the LM's `Imp.LM.Capability` (resolved by
  `Imp.LM.response_format_capability/1` at the call site). The arity-2 form is a
  capability-agnostic convenience that assumes a standard `response_format`-
  capable provider (the historical Imp default, `json_object`); real dispatch
  through `Imp.Predict`/`Imp.Streaming` uses the arity-3 form with the actual
  per-LM capability.

  Two explicit-override escape hatches are honored ahead of capability gating,
  with no DSPy analog: `native_json_schema: true` forces Imp's own json_schema
  envelope, and a caller-supplied `response_format` map is passed through
  untouched (returns `[]` so the caller's value wins).

  Signature-level `:code` outputs deliberately use a flat JSON string schema.
  That matches the actual JSON prompt and serialized value Imp accepts. Current
  DSPy exposes its pydantic `Code_<language>` wrapper as a `$ref` object in
  native response schema even though its JSONAdapter prompt and serializer use
  a string; Imp does not reproduce that internal pydantic mismatch.
  """
  def lm_opts(signature, opts) do
    opts = validate_lm_opts!(opts, "#{inspect(__MODULE__)}.lm_opts/2")
    build_lm_opts(signature, opts, Imp.LM.Capability.response_format_only())
  end

  def lm_opts(signature, opts, %Imp.LM.Capability{} = capability) do
    opts = validate_lm_opts!(opts, "#{inspect(__MODULE__)}.lm_opts/3")
    build_lm_opts(signature, opts, capability)
  end

  defp build_lm_opts(signature, opts, %Imp.LM.Capability{} = capability) do
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
        capability_response_format(signature, capability)
    end
  end

  # DSPy's three capability tiers, in order.
  defp capability_response_format(_signature, %Imp.LM.Capability{response_format: false}), do: []

  defp capability_response_format(signature, %Imp.LM.Capability{response_schema: true}) do
    # DSPy tries a structured schema and, if it cannot build one (open-ended
    # mapping, or a shape Imp cannot render byte-faithfully), falls back to
    # json_object — its `except Exception` clause. Nothing silent: the only
    # fallback is DSPy's own.
    case structured_response_format(signature) do
      {:ok, response_format} -> [response_format: response_format]
      :fallback -> [response_format: %{type: "json_object"}]
    end
  end

  defp capability_response_format(_signature, %Imp.LM.Capability{}),
    do: [response_format: %{type: "json_object"}]

  # DSPy `_get_structured_outputs_response_format` (a pydantic `DSPyProgramOutputs`
  # model) in the wire form litellm sends: `{"type": "json_schema", "json_schema":
  # {"name": "DSPyProgramOutputs", "schema": <model_json_schema>, "strict": true}}`.
  # Returns `:fallback` when any output is an open-ended mapping or a shape whose
  # pydantic schema Imp cannot reproduce byte-faithfully (DSPy's json_object path).
  defp structured_response_format(signature) do
    with {:ok, properties} <- output_properties(signature.outputs) do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => Map.new(properties),
        "required" => Enum.map(signature.outputs, &to_string(&1.name)),
        "title" => "DSPyProgramOutputs"
      }

      {:ok,
       %{
         type: "json_schema",
         json_schema: %{name: "DSPyProgramOutputs", schema: schema, strict: true}
       }}
    end
  rescue
    # CompositeType raises for shapes with no faithful pydantic schema (e.g. a
    # Literal nested in an array). DSPy's `except Exception` -> json_object.
    ArgumentError -> :fallback
  end

  defp output_properties(outputs) do
    Enum.reduce_while(outputs, {:ok, []}, fn field, {:ok, acc} ->
      case field_property_schema(field) do
        {:ok, schema} -> {:cont, {:ok, [{to_string(field.name), schema} | acc]}}
        :open_ended -> {:halt, :fallback}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :fallback -> :fallback
    end
  end

  # The pydantic property body for one output field, with pydantic's default
  # `title` (field name titlecased). Scalars carry only `type`; composites route
  # through CompositeType.
  defp field_property_schema(field) do
    case Imp.Adapter.CompositeType.pydantic_schema_body(field) do
      :scalar ->
        {:ok, %{"type" => scalar_json_type(field.type)} |> put_title(field.name)}

      :open_ended ->
        :open_ended

      {:ok, body} ->
        {:ok, put_title(body, field.name)}
    end
  end

  defp put_title(map, name), do: Map.put(map, "title", pydantic_title(name))

  # pydantic v2 default field title: `name.replace("_", " ").title()`.
  defp pydantic_title(name) do
    name
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # pydantic JSON-schema `type` for the scalar output types Imp models.
  defp scalar_json_type(:string), do: "string"
  defp scalar_json_type(:integer), do: "integer"
  defp scalar_json_type(:float), do: "number"
  defp scalar_json_type(:number), do: "number"
  defp scalar_json_type(:boolean), do: "boolean"
  defp scalar_json_type(:code), do: "string"
  defp scalar_json_type("string"), do: "string"
  defp scalar_json_type("integer"), do: "integer"
  defp scalar_json_type("float"), do: "number"
  defp scalar_json_type("number"), do: "number"
  defp scalar_json_type("boolean"), do: "boolean"
  defp scalar_json_type("code"), do: "string"

  defp code_field?(%{type: type}), do: type in [:code, "code"]

  defp code_language(field) do
    Map.get(field.metadata, :language, Map.get(field.metadata, "language", "python"))
    |> to_string()
  end

  defp code_annotation(field), do: "Code_#{code_language(field)}"

  @impl true
  def parse(signature, raw, opts) when is_map(raw),
    do: Imp.Adapter.Chat.parse(signature, raw, opts)

  # Faithful to DSPy JSONAdapter.parse (dspy/adapters/json_adapter.py):
  # repair-decode the completion (json_repair; Imp.Adapter.JSONRepair covers the
  # same Python-dict spellings — dee-16qm), and when that yields no object,
  # extract the first balanced `{...}` block and repair-decode that. A
  # completion with no JSON object is a LOUD AdapterParseError (upstream: "LM
  # response cannot be serialized to a JSON object."), never a lenient re-parse
  # through the chat dialect.
  def parse(signature, raw, opts) when is_binary(raw) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")

    case Imp.Adapter.JSONRepair.decode_object(extract_json(raw)) do
      {:ok, decoded} ->
        with {:ok, prediction} <- Imp.Adapter.Chat.parse(signature, decoded, opts),
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
        end

      :error ->
        {:error,
         %Imp.AdapterParseError{
           message: "LM response cannot be serialized to a JSON object.",
           reason: raw
         }}
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
