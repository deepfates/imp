defmodule Imp.Adapter.Chat do
  @moduledoc "Plain chat adapter: instructions plus field-labelled user content."

  @behaviour Imp.Adapter

  @format_option_schema [
    demos: [
      type: {:custom, __MODULE__, :validate_demos, []},
      default: []
    ],
    response_instruction: [type: :boolean, default: true],
    # Optional injectable renderer for demo/history ASSISTANT turns, letting a
    # delegating adapter (JSON) substitute its own serialization while reusing
    # Chat's message assembly. Arity 3: (signature, outputs, missing_message).
    output_renderer: [type: {:fun, 3}],
    # Optional injectable renderer for one INPUT-field section in user-facing
    # turns (main request, demos, history). DSPy's XMLAdapter overrides
    # `format_field_with_value`, which changes how EVERY input field renders
    # (`<name>\nvalue\n</name>` instead of `[[ ## name ## ]]\nvalue`); this seam
    # mirrors that polymorphism (dee-ovd3). Arity 2: (field, formatted_value)
    # where formatted_value is Chat's field-aware formatted string (blob lists,
    # scalars) — the renderer only wraps it in the adapter's dialect.
    input_section_renderer: [type: {:fun, 2}]
  ]

  @impl true
  def format(signature, inputs, opts) do
    opts = validate_format_opts!(opts, "#{inspect(__MODULE__)}.format/3")
    demos = opts[:demos]
    response_instruction? = opts[:response_instruction]
    # DSPy renders demo/history ASSISTANT turns through a polymorphic
    # `format_assistant_message_content`. ChatAdapter emits `[[ ## field ## ]]`
    # markers; JSONAdapter overrides it to emit a JSON object. Imp mirrors that
    # polymorphism with an injectable output renderer (default: Chat's own), so
    # the JSON adapter can override the assistant/output path instead of
    # delegating Chat's marker rendering (dee-0bwu).
    output_renderer = Keyword.get(opts, :output_renderer) || (&render_demo_outputs/3)
    input_renderer = Keyword.get(opts, :input_section_renderer) || (&chat_input_section/2)

    {history_messages, history_fields} =
      extract_history(signature, inputs, output_renderer, input_renderer)

    [%{role: :system, content: render_system(signature)}] ++
      render_demos(signature, demos, output_renderer, input_renderer) ++
      history_messages ++
      [
        %{
          role: :user,
          content:
            append_content(
              render_inputs(signature, inputs,
                skip: history_fields,
                section_renderer: input_renderer
              ),
              render_response_instruction(signature, response_instruction?)
            )
        }
      ]
  end

  @impl true
  def parse(signature, raw, opts) do
    validate_opts!(opts, "#{inspect(__MODULE__)}.parse/3")
    do_parse(signature, raw)
  end

  defp do_parse(_signature, %Imp.Prediction{} = prediction), do: {:ok, prediction}
  defp do_parse(signature, map) when is_map(map), do: build_prediction(signature, map)

  # Faithful port of DSPy 3.2.1 ChatAdapter.parse (dspy/adapters/chat_adapter.py):
  # the completion is split into `[[ ## field ## ]]`-headed sections; the FIRST
  # section for each output field wins; a completion whose sections do not cover
  # every output field is a LOUD parse error. There is deliberately no
  # single-output leniency (stuffing an unstructured completion into the lone
  # output field) and no in-parse JSON decode: a bad parse must FAIL so the
  # ChatAdapter->JSONAdapter fallback in Imp.Predict (DSPy `__call__`'s
  # fallback, a second LM call) can fire — nothing-silent (dee-coia).
  defp do_parse(signature, text) when is_binary(text) do
    build_prediction(signature, parse_marker_sections(signature, text))
  end

  defp do_parse(_signature, raw), do: {:error, {:unsupported_lm_output, raw}}

  @doc false
  def validate_demos(demos) do
    {:ok, Imp.Example.normalize_demos!(demos, "#{inspect(__MODULE__)}.format/3")}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp build_prediction(signature, fields) do
    required =
      signature.outputs
      |> Enum.reject(&(Map.get(&1.metadata, :optional) || Map.get(&1.metadata, "optional")))
      |> Enum.map(& &1.name)

    # PRESENT fields (even present-nil) are collected, then coerced with DSPy's
    # parse_value semantics BEFORE the required-field check: a str-annotated
    # field renders a present nil as "None" (Python str(None)); any field left
    # nil after coercion is genuinely absent/unusable and feeds the loud
    # missing-fields error.
    fields =
      signature.outputs
      |> Enum.filter(&field_present?(fields, &1.name))
      |> Map.new(fn field -> {field.name, fetch_field(fields, field.name)} end)
      |> then(&coerce_fields(signature, &1))
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.new()

    missing = Enum.reject(required, &Map.has_key?(fields, &1))

    with true <- missing == [],
         :ok <- Imp.Schema.validate_fields(signature.outputs, fields) do
      {:ok, Imp.Prediction.new(fields)}
    else
      false ->
        {:error, {:missing_output_fields, missing}}

      {:error, errors} ->
        {:error,
         %Imp.AdapterParseError{
           message: Imp.Schema.retry_feedback(errors),
           reason: fields
         }}
    end
  end

  defp coerce_fields(signature, fields) do
    signature.outputs
    |> Enum.reduce(fields, fn field, acc ->
      if Map.has_key?(acc, field.name),
        do: Map.update!(acc, field.name, &coerce_field(field, &1)),
        else: acc
    end)
  end

  # DSPy parse_value (dspy/adapters/utils.py) dispatch, in upstream order:
  # a Literal (Imp: enum-constrained string) gets quote/prefix stripping; a str
  # annotation gets Python `str(value)`; everything else keeps the typed
  # coercion clauses below.
  defp coerce_field(field, value) do
    case enum_constraint(field) do
      values when is_list(values) -> coerce_literal(value, values)
      _no_enum -> coerce_value(value, field.type)
    end
  end

  # parse_value's Literal branch: the raw value if allowed; otherwise (strings
  # only) strip a wrapping `Literal[...]`/`str[...]` spelling, then one pair of
  # wrapping quotes, and accept the stripped form when allowed. Anything else
  # keeps the raw value so schema validation reports the honest enum error
  # (dee-jbav).
  defp coerce_literal(value, allowed) do
    cond do
      value in allowed ->
        value

      is_binary(value) ->
        stripped =
          value
          |> String.trim()
          |> strip_literal_wrapper()
          |> strip_wrapping_quotes()

        if stripped in allowed, do: stripped, else: value

      true ->
        value
    end
  end

  # Python: `if v.startswith(("Literal[", "str[")) and v.endswith("]"):
  #            v = v[v.find("[") + 1 : -1]`
  defp strip_literal_wrapper(value) do
    if (String.starts_with?(value, "Literal[") or String.starts_with?(value, "str[")) and
         String.ends_with?(value, "]") do
      {index, 1} = :binary.match(value, "[")
      binary_part(value, index + 1, byte_size(value) - index - 2)
    else
      value
    end
  end

  # Python: `if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]`
  defp strip_wrapping_quotes(value) do
    with true <- String.length(value) > 1,
         first when first in ["\"", "'"] <- String.first(value),
         true <- first == String.last(value) do
      String.slice(value, 1..-2//1)
    else
      _no_strip -> value
    end
  end

  defp enum_constraint(field) do
    field.metadata
    |> fetch_meta(:constraints, %{})
    |> case do
      constraints when is_map(constraints) -> fetch_meta(constraints, :enum)
      _other -> nil
    end
  end

  # parse_value's `if annotation is str: return str(value)` — Python str() of
  # the parsed value: "None"/"True"/"False" spellings, repr-style rendering for
  # lists and dicts ("[1, 2, 3]"), floats in repr form (dee-jbav).
  defp coerce_value(value, :string), do: py_str(value)

  defp coerce_value(value, :integer) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> value
    end
  end

  defp coerce_value(value, :float) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      {_float, _rest} -> value
      :error -> value
    end
  end

  defp coerce_value(value, :number) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      {_float, _rest} -> value
      :error -> value
    end
  end

  defp coerce_value(value, :boolean) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      value when value in ["true", "yes", "1"] -> true
      value when value in ["false", "no", "0"] -> false
      _other -> value
    end
  end

  # Composite field types arrive from the chat wire as text (e.g. `["a","b"]`
  # or `{'k': 1}`). DSPy's `parse_value` decodes non-str field values through
  # the json_repair/ast.literal_eval ladder before handing them to validation
  # (utils.py: `candidate = json_repair.loads(value)`, ast fallback, then
  # `TypeAdapter(annotation).validate_python(candidate)`); on a decode miss it
  # falls back to the raw value and lets validation raise. We mirror that here
  # via Imp.Adapter.JSONRepair (strict JSON, then Python-dict spellings —
  # dee-16qm): decode the binary, and on failure return it unchanged so schema
  # validation produces the honest "expected array/object" error instead of
  # swallowing it.
  # Datetime fields parse from the ISO 8601 text the LM returns
  # (test_datetime_inputs_and_outputs: "2024-11-27T14:00:00" -> datetime).
  # An offset-carrying string yields a DateTime; a naive string yields a
  # NaiveDateTime. An unparsable string stays raw so schema validation
  # reports the honest "expected datetime" error.
  defp coerce_value(value, :datetime) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(trimmed) do
          {:ok, naive} -> naive
          {:error, _reason} -> value
        end
    end
  end

  defp coerce_value(value, :array) when is_binary(value), do: decode_composite(value)
  defp coerce_value(value, :object) when is_binary(value), do: decode_composite(value)

  defp coerce_value(value, _type), do: value

  defp decode_composite(value) do
    case Imp.Adapter.JSONRepair.decode(value) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  # Python `str(...)` as parse_value applies it to a str-annotated field.
  defp py_str(value) when is_binary(value), do: value
  defp py_str(nil), do: "None"
  defp py_str(true), do: "True"
  defp py_str(false), do: "False"
  defp py_str(value) when is_integer(value), do: Integer.to_string(value)
  defp py_str(value) when is_float(value), do: Imp.PyFloat.repr(value)

  defp py_str(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &py_repr/1) <> "]"

  defp py_str(value) when is_map(value) and not is_struct(value),
    do:
      "{" <> Enum.map_join(value, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"

  defp py_str(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp py_str(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp py_str(value) when is_atom(value), do: to_string(value)
  defp py_str(value), do: inspect(value)

  # Python `repr(...)` for elements nested in a str()-rendered list/dict:
  # strings quote (single quotes unless the string itself contains one and no
  # double quote); other scalars render as py_str.
  defp py_repr(value) when is_binary(value) do
    if String.contains?(value, "'") and not String.contains?(value, "\"") do
      "\"" <> value <> "\""
    else
      "'" <> String.replace(value, "'", "\\'") <> "'"
    end
  end

  defp py_repr(value), do: py_str(value)

  defp fetch_field(fields, name) do
    string_name = to_string(name)

    cond do
      Map.has_key?(fields, name) ->
        Map.fetch!(fields, name)

      Map.has_key?(fields, string_name) ->
        Map.fetch!(fields, string_name)

      (is_binary(name) and existing_atom(name)) && Map.has_key?(fields, existing_atom(name)) ->
        Map.fetch!(fields, existing_atom(name))

      true ->
        nil
    end
  end

  # Whether `name` is a PRESENT key (even with a nil value), across the atom,
  # string, and existing-atom spellings fetch_field understands. DSPy's
  # `k in demo` / `outputs.get(k, ...)` distinguish present-nil from absent;
  # fetch_field alone collapses both to nil, so key-presence needs its own path.
  defp field_present?(fields, name) do
    string_name = to_string(name)

    Map.has_key?(fields, name) or
      Map.has_key?(fields, string_name) or
      ((is_binary(name) and existing_atom(name)) && Map.has_key?(fields, existing_atom(name)))
  end

  defp render_inputs(signature, inputs, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    skip = opts |> Keyword.get(:skip, MapSet.new()) |> MapSet.new()
    section_renderer = Keyword.get(opts, :section_renderer) || (&chat_input_section/2)

    sections =
      signature.inputs
      |> Enum.reduce([], fn field, acc ->
        value = fetch_field(inputs, field.name)

        if is_nil(value) or MapSet.member?(skip, field.name) do
          acc
        else
          [render_input_section(field, value, section_renderer) | acc]
        end
      end)
      |> Enum.reverse()
      |> then(fn sections ->
        case prefix do
          "" -> sections
          _prefix -> [prefix | sections]
        end
      end)

    if Enum.any?(sections, &is_list/1) do
      sections
      |> Enum.intersperse("\n\n")
      |> List.flatten()
      |> merge_adjacent_text_parts()
    else
      Enum.join(sections, "\n\n")
    end
  end

  # Native multimodal content keeps Chat's marker header regardless of the
  # section renderer: DSPy's multimodal split (`split_message_content_for_custom
  # _types`) operates on the provider content parts, not the field dialect, and
  # no golden XML/native fixture exists to pin an alternative. Text values go
  # through the injectable section renderer (Chat markers by default, XML tags
  # for Imp.Adapter.XML).
  defp render_input_section(field, value, section_renderer) do
    if native_content?(value) do
      ["[[ ## #{field.name} ## ]]\n" | native_content_parts(value)]
    else
      section_renderer.(field, format_field_value(field, value))
    end
  end

  # Default (ChatAdapter) input-section dialect: `[[ ## name ## ]]\nvalue`.
  defp chat_input_section(field, formatted), do: "[[ ## #{field.name} ## ]]\n#{formatted}"

  # DSPy format_field_value (utils.py:57-59) special-cases a list value on a
  # `str`-annotated field, rendering it as a numbered guillemet blob list rather
  # than a JSON dump. This is the RAG-passages pattern (a `context` str field
  # carrying a list of retrieved passages). Every other value defers to
  # format_value/1. A list on an array-TYPED field (annotation list[...], not
  # str) keeps the json-dump path. (dee-tsce)
  defp format_field_value(field, value) when is_list(value) do
    # DSPy's `_format_blob` only accepts string elements (it raises TypeError on
    # anything else), so DSPy's list-on-str blob path is reachable in practice
    # only for a list of strings (or the empty list -> "N/A"). Restrict the blob
    # branch to exactly those cases; any other list (e.g. provider-native ReAct's
    # `tools` field carrying a list of tool-definition maps) keeps the prior
    # json-style rendering rather than crashing. (dee-tsce)
    if field_annotation(field) == "str" and Enum.all?(value, &is_binary/1) do
      format_input_list_field_value(value)
    else
      format_value(value)
    end
  end

  defp format_field_value(_field, value), do: format_value(value)

  # utils._format_input_list_field_value / _format_blob.
  defp format_input_list_field_value([]), do: "N/A"
  defp format_input_list_field_value([single]), do: format_blob(single)

  defp format_input_list_field_value(values) do
    values
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {value, index} -> "[#{index}] #{format_blob(value)}" end)
  end

  defp format_blob(blob) when is_binary(blob) do
    if String.contains?(blob, "\n") or String.contains?(blob, "«") or String.contains?(blob, "»") do
      "«««\n    " <> String.replace(blob, "\n", "\n    ") <> "\n»»»"
    else
      "«" <> blob <> "»"
    end
  end

  defp format_blob(blob), do: format_blob(to_string(blob))

  defp native_content?(value) when is_list(value), do: Enum.any?(value, &native_content?/1)
  defp native_content?(%Imp.Adapter.Types.Image{}), do: true
  defp native_content?(%Imp.Adapter.Types.Audio{}), do: true
  defp native_content?(%Imp.Adapter.Types.File{}), do: true
  defp native_content?(%Imp.Adapter.Types.Document{}), do: true
  defp native_content?(%Imp.Adapter.Types.Code{}), do: true
  defp native_content?(%Imp.Adapter.Types.Reasoning{}), do: true
  defp native_content?(%Imp.Adapter.Types.Citation{}), do: true
  defp native_content?(%Imp.Adapter.Types.Type{}), do: true
  defp native_content?(_value), do: false

  defp native_content_parts(values) when is_list(values),
    do: Enum.flat_map(values, &native_content_parts/1)

  defp native_content_parts(value) do
    if native_content?(value), do: [value], else: [format_value(value)]
  end

  defp merge_adjacent_text_parts(parts) do
    parts
    |> Enum.reduce([], fn
      text, [previous | rest] when is_binary(text) and is_binary(previous) ->
        [previous <> text | rest]

      part, acc ->
        [part | acc]
    end)
    |> Enum.reverse()
  end

  # Default (ChatAdapter) assistant-content renderer for demo/history turns.
  # Mirrors DSPy ChatAdapter.format_assistant_message_content:
  #   - value resolution is KEY-PRESENCE (`outputs.get(k, missing)`), not `|| `,
  #     so a legitimate `false`/`nil` output is kept, not replaced by the missing
  #     sentinel;
  #   - the joined field block is stripped ONCE (matching format_field_with_value)
  #     rather than per field, so interior trailing whitespace survives;
  #   - the trailing `\n\n[[ ## completed ## ]]\n` marker is ALWAYS appended.
  defp render_demo_outputs(signature, outputs, missing_field_message) do
    body =
      signature
      |> resolve_demo_outputs(outputs, missing_field_message)
      |> Enum.map_join("\n\n", fn {name, value} ->
        "[[ ## #{name} ## ]]\n#{format_value(value)}"
      end)
      |> String.trim()

    body <> "\n\n[[ ## completed ## ]]\n"
  end

  # Resolves a demo/history turn's output fields to ordered `{name, value}`
  # pairs, using DSPy's key-presence rule (`outputs.get(k, missing_field_message)`):
  # a present field (even nil/false) keeps its value; an absent field takes the
  # missing-field message. Shared with the JSON adapter so both assistant paths
  # resolve values identically and only differ in serialization (dee-u4st,
  # dee-0bwu). Internal cross-adapter seam — not public API (`@doc false`).
  @doc false
  def resolve_demo_outputs(signature, outputs, missing_field_message) do
    Enum.map(signature.outputs, fn field ->
      value =
        if field_present?(outputs, field.name) do
          fetch_field(outputs, field.name)
        else
          missing_field_message
        end

      {field.name, value}
    end)
  end

  defp render_system(signature) do
    """
    Your input fields are:
    #{render_field_list(signature.inputs)}
    Your output fields are:
    #{render_field_list(signature.outputs)}
    All interactions will be structured in the following way, with the appropriate values filled in.

    #{render_interaction_template(signature)}
    In adhering to this structure, your objective is: #{Imp.Adapter.Instructions.objective_text(signature.instructions)}
    """
    |> String.trim()
  end

  # Byte-faithful get_field_description_string, shared with the TwoStep
  # adapter's persona prompt (DSPy TwoStepAdapter.format_task_description calls
  # the same utils helper). Internal cross-adapter seam — not public API.
  @doc false
  def field_description_string(fields), do: render_field_list(fields)

  defp render_field_list(fields) do
    # Byte-faithful to DSPy's get_field_description_string (dspy/adapters/
    # utils.py): each field renders `N. \`name\` (type): {desc}` with the
    # colon-space always present, then the whole group is stripped — so a
    # field with no description keeps its trailing space only when it is not
    # the last line in its group. (epic dee-8zev / dee-l9vm, dee-qtzk)
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {field, index} ->
      "#{index}. `#{field.name}` (#{field_annotation(field)}): #{field_description(field)}"
    end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp field_description(field) do
    # DSPy renders a description equal to the "${name}" placeholder (the
    # ChainOfThought reasoning sentinel) as empty; match that exactly.
    desc = if field.desc == "${#{field.name}}", do: nil, else: field.desc

    [desc, answer_shape_instruction(field)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  defp answer_shape_instruction(field) do
    constraints =
      field.metadata
      |> fetch_meta(:constraints, %{})
      |> normalize_constraints()

    case fetch_meta(constraints, :answer_shape) do
      nil ->
        nil

      :yes_no ->
        "Must be exactly yes or no."

      "yes_no" ->
        "Must be exactly yes or no."

      :numeric_span ->
        "Must be only the numeric answer span, with no words or explanation."

      "numeric_span" ->
        "Must be only the numeric answer span, with no words or explanation."

      :short_span ->
        "Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."

      "short_span" ->
        "Must be a concise exact answer span; preserve complete names, titles, locations, dates, and quantities when the task asks for them, and do not add aliases, abbreviations, conversions, or parentheticals unless explicitly requested."

      other ->
        "Must satisfy answer shape #{inspect(other)}."
    end
  end

  defp render_interaction_template(signature) do
    # DSPy 3.2.1 ChatAdapter.format_field_structure renders each field's value
    # placeholder via translate_field_type: input fields (and str/Reasoning
    # outputs) get no note; typed OUTPUT fields get an 8-space-indented
    # "# note: the value you produce ..." suffix. Match it exactly (dee-3zun).
    input_lines = Enum.map(signature.inputs, &interaction_field_line(&1, ""))

    output_lines =
      Enum.map(signature.outputs, &interaction_field_line(&1, structure_type_note(&1)))

    (input_lines ++ output_lines)
    |> Kernel.++(["[[ ## completed ## ]]"])
    |> Enum.join("\n\n")
  end

  defp interaction_field_line(field, note) do
    """
    [[ ## #{field.name} ## ]]
    {#{field.name}}#{note}
    """
    |> String.trim()
  end

  # Faithful to DSPy 3.2.1 dspy/adapters/utils.py translate_field_type: the note
  # text keyed on the field's Python type. Emitted only for output fields.
  # Composite types (enum->Literal, array->list, object->dict) are handled first
  # via Imp.Adapter.CompositeType (dee-9ttv); scalars keep their existing clauses.
  defp structure_type_note(field) do
    case Imp.Adapter.CompositeType.note_desc(field) do
      nil -> scalar_structure_type_note(field)
      desc -> structure_note(desc)
    end
  end

  defp scalar_structure_type_note(field) do
    case field_type(field.type) do
      "str" -> ""
      "bool" -> structure_note("must be True or False")
      "int" -> structure_note("must be a single int value")
      "float" -> structure_note("must be a single float value")
      _ -> ""
    end
  end

  defp structure_note(desc),
    do: String.duplicate(" ", 8) <> "# note: the value you produce " <> desc

  defp field_type(:string), do: "str"
  defp field_type(:integer), do: "int"
  defp field_type(:float), do: "float"
  defp field_type(:number), do: "number"
  defp field_type(:boolean), do: "bool"
  defp field_type(type), do: to_string(type)

  defp fetch_meta(map, key, default \\ nil)

  defp fetch_meta(map, key, default) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp fetch_meta(map, key, default), do: Map.get(map, key, default)

  defp normalize_constraints(%{} = constraints) do
    Map.new(constraints, fn
      {"answerShape", value} -> {:answer_shape, value}
      {key, value} when is_binary(key) -> {existing_atom_or_key(key), value}
      pair -> pair
    end)
  end

  defp normalize_constraints(other), do: other

  defp existing_atom_or_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp render_response_instruction(_signature, false), do: ""

  defp render_response_instruction(signature, true) do
    # Byte-faithful to DSPy 3.2.1 ChatAdapter.user_message_output_requirements:
    # always singular "the field ", then every output marker joined with
    # ", then ", each carrying a Python-type note for non-str fields.
    # (epic dee-8zev / dee-l9vm, dee-3zun)
    markers =
      signature.outputs
      |> Enum.map(fn field -> "`[[ ## #{field.name} ## ]]`" <> output_type_info(field) end)
      |> Enum.join(", then ")

    "\n\nRespond with the corresponding output fields, starting with the field " <>
      markers <> ", and then ending with the marker for `[[ ## completed ## ]]`."
  end

  defp output_type_info(field) do
    case field_annotation(field) do
      "str" -> ""
      type_name -> " (must be formatted as a valid Python #{type_name})"
    end
  end

  # DSPy annotation name for a field: composite types (Literal/list/dict) resolve
  # through CompositeType; scalars fall back to the plain type-name mapping.
  defp field_annotation(field),
    do: Imp.Adapter.CompositeType.annotation_name(field) || field_type(field.type)

  defp append_content(content, ""), do: content
  defp append_content(content, suffix) when is_binary(content), do: content <> suffix

  defp append_content(content, suffix) when is_list(content),
    do: merge_adjacent_text_parts(content ++ [suffix])

  # DSPy formats scalars via Python `str(...)` after `serialize_for_json`:
  # `None -> "None"`, `True -> "True"`, `False -> "False"`. Elixir's
  # `to_string/1` would give "" / "true" / "false", so these three are pinned.
  # Public (`@doc false`) as an internal cross-adapter seam: the XML adapter's
  # demo/history assistant renderer resolves values through the SAME scalar
  # formatting so the adapters differ only in dialect (dee-ovd3).
  @doc false
  def format_value(value) when is_binary(value), do: value
  def format_value(nil), do: "None"
  def format_value(true), do: "True"
  def format_value(false), do: "False"

  def format_value(value) when is_atom(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  # Datetimes render as ISO 8601 (upstream serializes datetimes to their JSON
  # string form, e.g. "2024-11-25T10:00:00", before the prompt is built).
  def format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def format_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  def format_value(value), do: inspect(value)

  defp render_demos(_signature, [], _renderer, _input_renderer), do: []
  defp render_demos(_signature, nil, _renderer, _input_renderer), do: []

  defp render_demos(signature, demos, renderer, input_renderer) do
    {complete, incomplete} =
      demos
      |> Enum.map(&Imp.Example.to_map/1)
      |> Enum.reduce({[], []}, fn demo, {complete, incomplete} ->
        cond do
          complete_demo?(signature, demo) ->
            {[demo | complete], incomplete}

          usable_incomplete_demo?(signature, demo) ->
            {complete, [demo | incomplete]}

          true ->
            {complete, incomplete}
        end
      end)

    incomplete
    |> Enum.reverse()
    |> Enum.flat_map(&render_demo(signature, &1, :incomplete, renderer, input_renderer))
    |> Kernel.++(
      complete
      |> Enum.reverse()
      |> Enum.flat_map(&render_demo(signature, &1, :complete, renderer, input_renderer))
    )
  end

  defp extract_history(signature, inputs, renderer, input_renderer) do
    signature.inputs
    |> Enum.reduce({[], MapSet.new()}, fn field, {messages, fields} ->
      case fetch_field(inputs, field.name) do
        %Imp.History{} = history ->
          {messages ++
             render_history_turns(
               signature,
               Imp.History.messages(history),
               renderer,
               input_renderer
             ), MapSet.put(fields, field.name)}

        _other ->
          {messages, fields}
      end
    end)
  end

  defp render_history_turns(signature, turns, renderer, input_renderer) do
    turns
    |> Enum.flat_map(fn turn ->
      turn = Imp.Example.new(turn) |> Imp.Example.to_map()

      if native_tool_history_turn?(turn) do
        render_native_tool_history_turn(signature, turn)
      else
        [
          %{
            role: :user,
            content:
              render_inputs(signature, turn,
                skip: history_input_fields(signature),
                section_renderer: input_renderer
              )
          },
          %{
            role: :assistant,
            content:
              renderer.(signature, turn, "Not supplied for this conversation history message. ")
          }
        ]
        |> Enum.reject(&blank_message?/1)
      end
    end)
  end

  defp native_tool_history_turn?(turn), do: not is_nil(fetch_field(turn, :tool_calls))

  defp render_native_tool_history_turn(signature, turn) do
    calls = normalize_history_tool_calls(fetch_field(turn, :tool_calls))
    results = List.wrap(fetch_field(turn, :tool_call_results))

    user = %{
      role: :user,
      content: render_inputs(signature, turn, skip: history_input_fields(signature))
    }

    assistant = %{
      role: :assistant,
      content: fetch_field(turn, :next_thought) |> blank_to_empty(),
      tool_calls: calls
    }

    tool_messages =
      Enum.map(results, fn result ->
        id = fetch_field(result, :id)

        %{
          role: :tool,
          content: result |> fetch_field(:result) |> format_value(),
          tool_calls: [%{id: id}]
        }
      end)

    [user, assistant | tool_messages]
    |> Enum.reject(fn
      %{role: :assistant, tool_calls: calls} -> calls == []
      message -> blank_message?(message)
    end)
  end

  defp normalize_history_tool_calls(%Imp.Adapter.Types.ToolCalls{tool_calls: calls}),
    do: Enum.map(calls, &Imp.Adapter.Types.ToolCall.format/1)

  # Redaction intentionally converts structs to credential-safe maps before an
  # event is stored in history. Preserve the collection envelope so replay still
  # emits the assistant tool-use message required before provider tool results.
  defp normalize_history_tool_calls(%{tool_calls: calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(%{"tool_calls" => calls}),
    do: normalize_history_tool_calls(calls)

  defp normalize_history_tool_calls(calls) when is_list(calls) do
    calls
    |> Imp.Adapter.Types.ToolCalls.new()
    |> normalize_history_tool_calls()
  end

  defp normalize_history_tool_calls(_calls), do: []

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(value), do: to_string(value)

  defp history_input_fields(signature) do
    signature.inputs
    |> Enum.filter(&(&1.type == :history or &1.name == :history))
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp blank_message?(%{content: content}) when is_binary(content), do: String.trim(content) == ""

  defp blank_message?(%{content: content}) when is_list(content) do
    Enum.all?(content, fn
      text when is_binary(text) -> String.trim(text) == ""
      _part -> false
    end)
  end

  defp complete_demo?(signature, demo) do
    (signature.inputs ++ signature.outputs)
    |> Enum.all?(fn field -> not is_nil(fetch_field(demo, field.name)) end)
  end

  # DSPy base.format_demos keeps an incomplete demo when it has at least one
  # input field and one output field PRESENT (`any(k in demo ...)`), regardless
  # of whether their values are nil. Key-presence, not `not is_nil`, so a
  # present-but-nil output field no longer drops the whole demo (dee-u4st).
  defp usable_incomplete_demo?(signature, demo) do
    Enum.any?(signature.inputs, fn field -> field_present?(demo, field.name) end) and
      Enum.any?(signature.outputs, fn field -> field_present?(demo, field.name) end)
  end

  defp render_demo(signature, demo, :incomplete, renderer, input_renderer) do
    [
      %{
        role: :user,
        content:
          render_inputs(signature, demo,
            prefix:
              "This is an example of the task, though some input or output fields are not supplied.",
            section_renderer: input_renderer
          )
      },
      %{
        role: :assistant,
        content: renderer.(signature, demo, "Not supplied for this particular example. ")
      }
    ]
  end

  defp render_demo(signature, demo, :complete, renderer, input_renderer) do
    [
      %{role: :user, content: render_inputs(signature, demo, section_renderer: input_renderer)},
      %{
        role: :assistant,
        content:
          renderer.(signature, demo, "Not supplied for this conversation history message. ")
      }
    ]
  end

  # DSPy's `field_header_pattern = re.compile(r"\[\[ ## (\w+) ## \]\]")`,
  # matched (re.match) against each STRIPPED line.
  @field_header_pattern ~r/^\[\[ ## (\w+) ## \]\]/u

  # ChatAdapter.parse section scanning, ported line-for-line:
  #   * `completion.splitlines()`;
  #   * a line whose stripped form starts with the header pattern opens a new
  #     section; the remainder of the line past the match becomes the first
  #     content line when non-empty (upstream slices the ORIGINAL line at the
  #     stripped match end — that quirk is reproduced);
  #   * every other line appends to the current section;
  #   * sections are joined with "\n" and stripped;
  #   * only headers naming an output field count, FIRST occurrence wins,
  #     name match is exact (no downcasing, no `name:` label lines).
  defp parse_marker_sections(signature, text) do
    allowed = Map.new(signature.outputs, fn field -> {to_string(field.name), field.name} end)

    text
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.reduce([{nil, []}], fn line, [{header, lines} | rest] ->
      trimmed = String.trim(line)

      case Regex.run(@field_header_pattern, trimmed) do
        [full, section_header] ->
          remaining = line |> String.slice(String.length(full)..-1//1) |> String.trim()
          content = if remaining == "", do: [], else: [remaining]
          [{section_header, content}, {header, lines} | rest]

        nil ->
          [{header, [line | lines]} | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn
      {nil, _lines}, acc ->
        acc

      {header, lines}, acc ->
        case Map.fetch(allowed, header) do
          {:ok, field_name} ->
            value = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
            Map.put_new(acc, field_name, value)

          :error ->
            acc
        end
    end)
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp validate_format_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Keyword.take(Keyword.keys(@format_option_schema))
      |> Imp.Options.validate!(@format_option_schema, context)
    else
      raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_format_opts!(opts, context) do
    raise ArgumentError, "#{context}: expected keyword options, got: #{inspect(opts)}"
  end

  defp validate_opts!(opts, _context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      raise ArgumentError,
            "#{inspect(__MODULE__)}.parse/3 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end
