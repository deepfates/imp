defmodule Imp.Adapter.XML do
  @moduledoc """
  XML adapter with DSPy's field dialect and current output-completion contract.

  One XML-only dialect end to end: the system message renders the interaction
  structure as `<field>\\n{field}\\n</field>` blocks (no `[[ ## ]]` markers and
  no `completed` sentinel), user turns wrap every input value in its field tag,
  demo/history assistant turns wrap every output value in its field tag, and
  the main request ends with DSPy's exact output requirement sentence
  ("Respond with the corresponding output fields wrapped in XML tags ...").

  Parse fills declared output defaults and omitted nullable fields, then returns
  `{:error, {:missing_output_fields, missing}}` if any required output remains
  absent. Tag-free prose is a loud error, never silently stuffed into a field.

  Rendering is byte-verified against real DSPy 3.2.1 by the golden-trace
  differential (`test/fixtures/golden_trace/cases.json`, `xml_*` cases).
  """

  @behaviour Imp.Adapter

  @impl true
  def format(signature, inputs, opts) do
    # DSPy XMLAdapter subclasses ChatAdapter and overrides only the field
    # dialect (`format_field_with_value`), the structure/system text, and the
    # output-requirements sentence; message assembly (demos, history, main
    # request) is inherited. Mirror that by delegating to Chat.format with the
    # XML input-section and assistant renderers injected, then substituting
    # the XML system message and appending the XML output requirements to the
    # main-request user message.
    format_opts =
      opts
      |> Keyword.put(:response_instruction, false)
      |> Keyword.put(:output_renderer, &render_assistant_xml/3)
      |> Keyword.put(:input_section_renderer, &xml_input_section/2)

    [_chat_system | rest] = Imp.Adapter.Chat.format(signature, inputs, format_opts)

    [
      %{role: :system, content: render_system(signature)}
      | append_output_requirements(rest, signature)
    ]
  end

  @impl true
  def parse(signature, raw, opts) when is_binary(raw) do
    output_names = Imp.Signature.output_names(signature)

    fields =
      Enum.reduce(output_names, %{}, fn name, acc ->
        pattern = ~r/<#{name}>\s*(.*?)\s*<\/#{name}>/s

        case Regex.run(pattern, raw) do
          [_all, value] -> Map.put(acc, name, String.trim(value))
          nil -> acc
        end
      end)

    # DSPy XMLAdapter.parse (dspy/adapters/xml_adapter.py) raises
    # AdapterParseError unless every output field is present in tags:
    # `if fields.keys() != signature.output_fields.keys(): raise ...`.
    # Tag-free prose must be a loud parse error (feeding the retry path),
    # never silently stuffed into an output field via the Chat fallback.
    required_names =
      signature.outputs
      |> Enum.filter(&Imp.Adapter.OutputFields.required?/1)
      |> Enum.map(& &1.name)

    case Enum.reject(required_names, &Map.has_key?(fields, &1)) do
      [] -> Imp.Adapter.Chat.parse(signature, fields, opts)
      missing -> {:error, {:missing_output_fields, missing}}
    end
  end

  def parse(signature, raw, opts), do: Imp.Adapter.Chat.parse(signature, raw, opts)

  # ------------------------------------------------------------------
  # XMLAdapter.format_field_with_value dialect for one INPUT section:
  # `<name>\nvalue\n</name>`. The formatted value arrives from Chat's shared
  # field-aware formatter (format_field_value), matching DSPy where the same
  # utils.format_field_value feeds both adapters.
  defp xml_input_section(field, formatted), do: "<#{field.name}>\n#{formatted}\n</#{field.name}>"

  # Demo / history ASSISTANT-turn renderer injected into Chat.format.
  # Mirrors DSPy XMLAdapter.format_assistant_message_content:
  #   format_field_with_value({field: outputs.get(k, missing_field_message)})
  # -> `<name>\nvalue\n</name>` blocks joined by blank lines, stripped once,
  # with NO trailing `[[ ## completed ## ]]` marker (that is Chat's dialect).
  defp render_assistant_xml(signature, outputs, missing_field_message) do
    signature
    |> Imp.Adapter.Chat.resolve_demo_outputs(outputs, missing_field_message)
    |> Enum.map_join("\n\n", fn {name, value} ->
      "<#{name}>\n#{Imp.Adapter.Chat.format_value(value)}\n</#{name}>"
    end)
    |> String.trim()
  end

  # DSPy XMLAdapter appends `user_message_output_requirements` to the MAIN
  # request user message only (`main_request: true`), which in Chat's message
  # list is always the last message.
  defp append_output_requirements(messages, signature) do
    tail = "\n\n" <> user_message_output_requirements(signature)
    {init, [last]} = Enum.split(messages, -1)
    init ++ [Map.update!(last, :content, &append_text(&1, tail))]
  end

  defp append_text(content, suffix) when is_binary(content), do: content <> suffix
  defp append_text(content, suffix) when is_list(content), do: content ++ [suffix]

  # XMLAdapter.user_message_output_requirements: tags only, no Python-type
  # notes (those are Chat/JSON dialect; XML carries types in the structure
  # notes instead).
  defp user_message_output_requirements(signature) do
    "Respond with the corresponding output fields wrapped in XML tags " <>
      Enum.map_join(signature.outputs, ", then ", &"`<#{&1.name}>`") <> "."
  end

  # ------------------------------------------------------------------
  # System message: ChatAdapter.format_field_description (inherited) +
  # XMLAdapter.format_field_structure + ChatAdapter.format_task_description,
  # joined with single newlines (base.Adapter.format_system_message).
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

  # DSPy get_field_description_string renders a description equal to the
  # "${name}" placeholder (the ChainOfThought reasoning sentinel) as empty.
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

  # XMLAdapter.format_field_structure: the same lead sentence as Chat, then
  # every input and output field as an XML-wrapped `translate_field_type`
  # placeholder — and NO `[[ ## completed ## ]]` terminator (that append is
  # ChatAdapter's override, absent from XMLAdapter's).
  defp field_structure(signature) do
    [
      "All interactions will be structured in the following way, with the appropriate values filled in.",
      structure_block(signature.inputs, :input),
      structure_block(signature.outputs, :output)
    ]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp structure_block(fields, role) do
    Enum.map_join(fields, "\n\n", fn field ->
      "<#{field.name}>\n" <> translate_field_type(field, role) <> "\n</#{field.name}>"
    end)
  end

  # utils.translate_field_type: input fields (and str outputs) carry no note;
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

  # Composite output fields (enum->Literal, array->list, object->dict) note
  # first via the shared CompositeType module; scalars keep their type notes.
  defp output_note_desc(field),
    do: Imp.Adapter.CompositeType.note_desc(field) || type_note(field.type)

  defp type_note(:string), do: nil
  defp type_note(:integer), do: "must be a single int value"
  defp type_note(:float), do: "must be a single float value"
  defp type_note(:boolean), do: "must be True or False"
  # `:number` has no native DSPy counterpart; treat like float for the note.
  defp type_note(:number), do: "must be a single float value"
  defp type_note(_type), do: nil

  # ChatAdapter.format_task_description (inherited by XMLAdapter).
  defp task_description(signature) do
    "In adhering to this structure, your objective is: " <>
      Imp.Adapter.Instructions.objective_text(signature.instructions)
  end

  # DSPy annotation name for a field: composite types (Literal/list/dict)
  # resolve through the shared CompositeType module; scalars map directly.
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

  defp code_field?(%{type: type}), do: type in [:code, "code"]

  defp code_language(field) do
    Map.get(field.metadata, :language, Map.get(field.metadata, "language", "python"))
    |> to_string()
  end

  defp code_annotation(field), do: "Code_#{code_language(field)}"
end
