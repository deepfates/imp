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
  an `Imp.AdapterParseError` of kind `:missing_fields` if any required output
  remains absent. Typed objects, arrays, mappings, and unions use recursive XML. Saxy
  parses completed responses; declarations, doctypes, and custom entities are
  rejected before parsing. Tag-free prose is a loud error, never silently
  stuffed into a field.

  Rendering is byte-verified against real DSPy 3.2.1 by the golden-trace
  differential (`test/fixtures/golden_trace/cases.json`, `xml_*` cases).
  """

  @behaviour Imp.Adapter

  @max_xml_depth 64
  @max_xml_elements 10_000

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
    with {:ok, root} <- parse_fragment(raw),
         grouped <- group_children(root),
         {:ok, fields} <- parse_output_fields(signature.outputs, grouped, raw),
         {:ok, prediction} <- Imp.Adapter.Chat.parse(signature, fields, opts) do
      {:ok, prediction}
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
    resolved =
      Map.new(Imp.Adapter.Chat.resolve_demo_outputs(signature, outputs, missing_field_message))

    Enum.map_join(signature.outputs, "\n\n", fn field ->
      value = Map.fetch!(resolved, field.name)

      if nested_xml?(field) and (is_map(value) or is_list(value)) do
        value_to_xml(value, to_string(field.name))
      else
        formatted = Imp.Adapter.Chat.format_value(value)
        formatted = if string_type?(field.type), do: escape_text(formatted), else: formatted
        "<#{field.name}>\n#{formatted}\n</#{field.name}>"
      end
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
    base =
      "Respond with the corresponding output fields wrapped in XML tags " <>
        Enum.map_join(signature.outputs, ", then ", &"`<#{&1.name}>`") <> "."

    schemas =
      signature.outputs
      |> Enum.filter(&nested_xml?/1)
      |> Enum.map_join(" ", &schema_to_xml(to_string(&1.name), field_spec(&1)))

    if schemas == "", do: base, else: base <> " Use this nested XML structure: " <> schemas
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
      if role == :output and nested_xml?(field) do
        schema_to_xml(to_string(field.name), field_spec(field))
      else
        "<#{field.name}>\n" <> translate_field_type(field, role) <> "\n</#{field.name}>"
      end
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

  # ------------------------------------------------------------------
  # DSPy 3.3.1 recursive XML values.

  defp parse_fragment(raw) do
    if Regex.match?(~r/<!(?:DOCTYPE|ENTITY)|<\?xml/i, raw) do
      xml_error(raw, "XML declarations, doctypes, and entities are not allowed")
    else
      case Saxy.SimpleForm.parse_string("<dspy_root>" <> raw <> "</dspy_root>") do
        {:ok, root} -> validate_tree(root, raw)
        {:error, reason} -> xml_error(raw, "Failed to parse XML: #{format_reason(reason)}")
      end
    end
  rescue
    error -> xml_error(raw, "Failed to parse XML: #{Exception.message(error)}")
  end

  defp xml_error(raw, message) do
    {:error, %Imp.AdapterParseError{kind: :malformed, message: message, reason: raw}}
  end

  defp validate_tree(root, raw) do
    case tree_stats(root, 1) do
      {:ok, count, depth} when count <= @max_xml_elements and depth <= @max_xml_depth ->
        {:ok, root}

      {:ok, count, _depth} when count > @max_xml_elements ->
        xml_error(raw, "XML response exceeds #{@max_xml_elements} elements")

      {:ok, _count, depth} ->
        xml_error(raw, "XML response exceeds depth #{@max_xml_depth} (got #{depth})")
    end
  end

  defp tree_stats({_name, _attrs, children}, depth) do
    Enum.reduce_while(children, {:ok, 1, depth}, fn
      {_name, _attrs, _children} = child, {:ok, count, max_depth} ->
        case tree_stats(child, depth + 1) do
          {:ok, child_count, child_depth} ->
            count = count + child_count
            max_depth = max(max_depth, child_depth)

            if count > @max_xml_elements or max_depth > @max_xml_depth,
              do: {:halt, {:ok, count, max_depth}},
              else: {:cont, {:ok, count, max_depth}}
        end

      _text, stats ->
        {:cont, stats}
    end)
  end

  defp parse_output_fields(fields, grouped, raw) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, parsed} ->
      case Map.fetch(grouped, to_string(field.name)) do
        :error ->
          {:cont, {:ok, parsed}}

        {:ok, nodes} ->
          case elements_to_value(nodes, field_spec(field)) do
            {:ok, value} -> {:cont, {:ok, Map.put(parsed, field.name, value)}}
            {:error, reason} -> {:halt, xml_field_error(raw, field, reason)}
          end
      end
    end)
  end

  defp xml_field_error(raw, field, reason) do
    {:error,
     %Imp.AdapterParseError{
       kind: :invalid_fields,
       message: "Failed to parse XML field #{field.name}: #{reason}",
       reason: raw
     }}
  end

  defp elements_to_value([node | _] = nodes, spec) do
    cond do
      nullable?(spec) and empty_node?(node) ->
        {:ok, nil}

      spec_type(spec) == :array ->
        parse_array_nodes(nodes, spec)

      spec_type(spec) == :object ->
        parse_object_node(node, spec)

      spec_type(spec) == :union ->
        parse_union_nodes(nodes, spec)

      spec_type(spec) == :null and empty_node?(node) ->
        {:ok, nil}

      spec_type(spec) == :null ->
        {:error, "expected an empty null element"}

      true ->
        parse_scalar(node_text(node), spec_type(spec))
    end
  end

  defp parse_array_nodes([node] = nodes, spec) do
    text = node_text(node)
    children = element_children(node)

    cond do
      children == [] and text == "" ->
        {:ok, []}

      children == [] and String.starts_with?(text, "[") ->
        case Imp.Adapter.JSONRepair.decode(text) do
          {:ok, value} when is_list(value) -> {:ok, value}
          _ -> parse_array_items(nodes, item_spec(spec))
        end

      item_nodes = Map.get(group_children(node), "item") ->
        parse_array_items(item_nodes, item_spec(spec))

      true ->
        parse_array_items(nodes, item_spec(spec))
    end
  end

  defp parse_array_nodes(nodes, spec), do: parse_array_items(nodes, item_spec(spec))

  defp parse_array_items(nodes, spec) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, values} ->
      case elements_to_value([node], spec) do
        {:ok, value} -> {:cont, {:ok, values ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_object_node(node, spec) do
    text = node_text(node)
    children = group_children(node)

    cond do
      map_size(children) == 0 and text == "" ->
        {:ok, %{}}

      map_size(children) == 0 and String.starts_with?(text, "{") ->
        case Imp.Adapter.JSONRepair.decode(text) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:error, "expected an object"}
        end

      map_size(children) == 0 ->
        {:error, "expected nested object fields or a JSON object"}

      true ->
        properties = spec_properties(spec)
        additional = spec_additional_properties(spec)

        Enum.reduce_while(children, {:ok, %{}}, fn {name, nodes}, {:ok, values} ->
          child_spec = fetch_key(properties, name, additional || infer_node_spec(nodes))

          case elements_to_value(nodes, child_spec) do
            {:ok, value} -> {:cont, {:ok, Map.put(values, name, value)}}
            {:error, reason} -> {:halt, {:error, "#{name}: #{reason}"}}
          end
        end)
    end
  end

  defp parse_union_nodes(nodes, spec) do
    spec
    |> union_branches()
    |> Enum.reduce_while({:error, "did not match any allowed type"}, fn branch, _last_error ->
      case elements_to_value(nodes, branch) do
        {:ok, value} ->
          if valid_for_spec?(value, branch),
            do: {:halt, {:ok, value}},
            else: {:cont, {:error, "did not match #{inspect(spec_type(branch))}"}}

        {:error, reason} ->
          {:cont, {:error, reason}}
      end
    end)
  end

  defp valid_for_spec?(value, spec) do
    field =
      Imp.Signature.Field.new(
        %{
          name: :xml_value,
          type: spec_type(spec),
          constraints: spec_constraints(spec),
          optional: nullable?(spec)
        },
        :output
      )

    Imp.Schema.validate_field(field, value) == []
  end

  defp parse_scalar(text, :integer) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, "expected integer, got #{inspect(text)}"}
    end
  end

  defp parse_scalar(text, type) when type in [:float, :number] do
    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, "expected number, got #{inspect(text)}"}
    end
  end

  defp parse_scalar(text, :boolean) do
    case String.downcase(text) do
      value when value in ["true", "yes", "1"] -> {:ok, true}
      value when value in ["false", "no", "0"] -> {:ok, false}
      _ -> {:error, "expected boolean, got #{inspect(text)}"}
    end
  end

  defp parse_scalar(text, :datetime) do
    case DateTime.from_iso8601(text) do
      {:ok, value, _offset} ->
        {:ok, value}

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(text) do
          {:ok, value} -> {:ok, value}
          {:error, _reason} -> {:error, "expected ISO 8601 datetime, got #{inspect(text)}"}
        end
    end
  end

  defp parse_scalar(text, :any) do
    case Imp.Adapter.JSONRepair.decode(text) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, text}
    end
  end

  defp parse_scalar(text, _type), do: {:ok, text}

  defp group_children({_name, _attrs, children}) do
    Enum.reduce(children, %{}, fn
      {name, attrs, _children} = child, grouped ->
        key = if name == "entry", do: attr(attrs, "key") || name, else: name
        Map.update(grouped, key, [child], &(&1 ++ [child]))

      _text, grouped ->
        grouped
    end)
  end

  defp element_children({_name, _attrs, children}),
    do: Enum.filter(children, &match?({_, _, _}, &1))

  defp node_text({_name, _attrs, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
    |> String.trim()
  end

  defp empty_node?(node), do: element_children(node) == [] and node_text(node) == ""

  defp attr(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  defp field_spec(field) do
    %{
      type: normalize_type(field.type),
      constraints: fetch_key(field.metadata, :constraints, %{}),
      optional: Imp.Adapter.OutputFields.optional?(field)
    }
  end

  defp nested_xml?(field), do: spec_type(field_spec(field)) in [:array, :object]

  defp item_spec(spec) do
    constraints = spec_constraints(spec)

    case fetch_key(constraints, :items) do
      nil -> %{type: :any}
      items when is_map(items) -> items
    end
  end

  defp spec_properties(spec),
    do: spec |> spec_constraints() |> fetch_key(:properties, %{})

  defp spec_additional_properties(spec),
    do: spec |> spec_constraints() |> fetch_key(:additional_properties)

  defp union_branches(spec), do: spec |> spec_constraints() |> fetch_key(:any_of, [])

  defp spec_constraints(spec) do
    fetch_key(spec, :constraints, %{})
    |> Map.merge(
      Map.drop(spec, [:type, "type", :constraints, "constraints", :optional, "optional"])
    )
  end

  defp spec_type(spec), do: spec |> fetch_key(:type, :string) |> normalize_type()
  defp nullable?(spec), do: fetch_key(spec, :optional, false) == true

  defp normalize_type(type) when type in [:array, "array"], do: :array

  defp normalize_type(type) when type in [:object, "object", :map, "map", :dict, "dict"],
    do: :object

  defp normalize_type(type) when type in [:integer, "integer", :int, "int"], do: :integer
  defp normalize_type(type) when type in [:float, "float"], do: :float
  defp normalize_type(type) when type in [:number, "number"], do: :number
  defp normalize_type(type) when type in [:boolean, "boolean", :bool, "bool"], do: :boolean
  defp normalize_type(type) when type in [:datetime, "datetime"], do: :datetime
  defp normalize_type(type) when type in [:any, "any"], do: :any
  defp normalize_type(type) when type in [:union, "union"], do: :union
  defp normalize_type(type) when type in [:null, "null", nil], do: :null
  defp normalize_type(_type), do: :string

  defp infer_node_spec([node | _] = nodes) do
    item_type = if element_children(node) == [], do: :string, else: :object

    if length(nodes) > 1,
      do: %{type: :array, constraints: %{items: %{type: item_type}}},
      else: %{type: item_type}
  end

  defp schema_to_xml(tag, spec) do
    case spec_type(spec) do
      :array -> "<#{tag}>" <> schema_to_xml("item", item_spec(spec)) <> "</#{tag}>"
      :object -> object_schema_to_xml(tag, spec_properties(spec))
      :union -> schema_to_xml(tag, preferred_union_branch(spec))
      _scalar -> "<#{tag}>...</#{tag}>"
    end
  end

  defp preferred_union_branch(spec) do
    spec
    |> union_branches()
    |> Enum.reject(&(spec_type(&1) == :null))
    |> List.first()
    |> Kernel.||(%{type: :string})
  end

  defp object_schema_to_xml(tag, properties) when map_size(properties) == 0,
    do: "<#{tag}>...</#{tag}>"

  defp object_schema_to_xml(tag, properties) do
    children =
      Enum.map_join(properties, fn {name, spec} -> schema_to_xml(to_string(name), spec) end)

    "<#{tag}>#{children}</#{tag}>"
  end

  defp value_to_xml(%_{} = value, tag), do: value |> Map.from_struct() |> value_to_xml(tag)

  defp value_to_xml(value, tag) when is_list(value) do
    case Enum.map_join(value, &value_to_xml(&1, "item")) do
      "" -> "<#{tag} />"
      children -> "<#{tag}>#{children}</#{tag}>"
    end
  end

  defp value_to_xml(value, tag) when is_map(value) do
    children =
      Enum.map_join(value, fn {key, child} ->
        name = to_string(key)

        if valid_xml_name?(name) do
          value_to_xml(child, name)
        else
          value_to_xml_with_key(child, "entry", name)
        end
      end)

    "<#{tag}>#{children}</#{tag}>"
  end

  defp value_to_xml(nil, tag), do: "<#{tag} />"
  defp value_to_xml(value, tag), do: "<#{tag}>#{escape_text(to_string(value))}</#{tag}>"

  defp value_to_xml_with_key(value, tag, key) do
    rendered = value_to_xml(value, tag)
    String.replace_prefix(rendered, "<#{tag}", "<#{tag} key=\"#{escape_attr(key)}\"")
  end

  defp valid_xml_name?(name), do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_.-]*$/, name)

  defp escape_text(value),
    do: value |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")

  defp escape_attr(value) do
    value
    |> escape_text()
    |> String.replace("\"", "&quot;")
    |> String.replace("\n", "&#10;")
    |> String.replace("\r", "&#13;")
    |> String.replace("\t", "&#9;")
  end

  defp string_type?(type), do: normalize_type(type) == :string

  defp fetch_key(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_alternate_key(map, key, default)
    end
  end

  defp fetch_alternate_key(map, key, default) when is_atom(key),
    do: Map.get(map, Atom.to_string(key), default)

  defp fetch_alternate_key(map, key, default) when is_binary(key) do
    Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end

  defp fetch_alternate_key(_map, _key, default), do: default

  defp format_reason(%_{} = reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
