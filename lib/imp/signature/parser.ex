defmodule Imp.Signature.ParseError do
  defexception [:message, :input, :position]

  def exception(opts) do
    input = Keyword.fetch!(opts, :input)
    position = Keyword.fetch!(opts, :position)
    detail = Keyword.fetch!(opts, :detail)
    suggestion = Keyword.get(opts, :suggestion)
    note = Keyword.get(opts, :note)

    pointer =
      input
      |> String.slice(0, position)
      |> String.replace(~r/[^\n]/, " ")
      |> Kernel.<>("^")

    message =
      [
        "invalid signature at position #{position}: #{detail}",
        input,
        pointer,
        if(suggestion,
          do: "did you mean #{inspect(suggestion)}?" <> if(note, do: " #{note}", else: ""),
          else: nil
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    %__MODULE__{message: message, input: input, position: position}
  end
end

defmodule Imp.Signature.Parser do
  @moduledoc false

  alias Imp.Signature.Field

  # Includes the Python spellings DSPy string signatures accept for types Imp
  # models: `str` (upstream tests/signatures/test_signature.py::
  # test_typed_signatures_basic_types, dee-1nkd) and `dict`. Python's `list[...]`
  # keeps its guided ParseError pointing at `array[...]` (see suggest_type/1).
  @types %{
    "string" => :string,
    "str" => :string,
    "number" => :number,
    "integer" => :integer,
    "int" => :integer,
    "float" => :float,
    "boolean" => :boolean,
    "bool" => :boolean,
    "datetime" => :datetime,
    "object" => :object,
    "map" => :object,
    "dict" => :object
  }

  @answer_shapes %{
    "yes_no" => :yes_no,
    "short_span" => :short_span,
    "numeric_span" => :numeric_span
  }

  def parse(spec) when is_binary(spec) do
    case split_arrow(spec) do
      {:ok, raw_inputs, raw_outputs} ->
        inputs = parse_fields(spec, raw_inputs, :input, 0)
        outputs = parse_fields(spec, raw_outputs, :output, arrow_end(spec))
        check_distinct_names!(spec, inputs, outputs)
        {inputs, outputs}

      :error ->
        raise Imp.Signature.ParseError,
          input: spec,
          position: max(String.length(spec) - 1, 0),
          detail: "signature must contain exactly one `->`"
    end
  end

  # DSPy `_parse_signature` (dspy/signatures/signature.py) raises when a name
  # appears on both sides of the arrow ("Input and output fields must have
  # distinct names..."). A silently shared name would make one field shadow the
  # other in prompts and parses — nothing-silent (dee-1nkd; upstream
  # tests/signatures/test_signature.py::test_duplicate_input_output_field_names_raise).
  defp check_distinct_names!(spec, inputs, outputs) do
    input_names = MapSet.new(inputs, & &1.name)

    duplicates =
      outputs
      |> Enum.map(& &1.name)
      |> Enum.filter(&MapSet.member?(input_names, &1))
      |> Enum.sort()

    if duplicates != [] do
      raise Imp.Signature.ParseError,
        input: spec,
        position: arrow_end(spec),
        detail:
          "input and output fields must have distinct names, but found duplicates: " <>
            "'#{Enum.join(duplicates, ", ")}'"
    end
  end

  defp split_arrow(spec) do
    case :binary.matches(spec, "->") do
      [{index, 2}] ->
        {:ok, binary_part(spec, 0, index),
         binary_part(spec, index + 2, byte_size(spec) - index - 2)}

      _other ->
        :error
    end
  end

  defp arrow_end(spec) do
    [{index, 2}] = :binary.matches(spec, "->")
    index + 2
  end

  defp parse_fields(spec, raw, kind, offset) do
    raw
    |> split_fields()
    |> Enum.map(fn {field, local_position} ->
      parse_field(spec, String.trim(field), kind, offset + local_position)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_field(_spec, "", _kind, _position), do: nil

  defp parse_field(spec, raw, kind, position) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)(?:\s*:\s*(.+?))?(?:\s+"([^"]+)")?$/, raw) do
      [_, name] ->
        Field.new(%{name: name}, kind)

      [_, name, type_spec] ->
        {type, metadata} = parse_type(spec, type_spec, position + byte_size(name) + 1)
        Field.new(%{name: name, type: type, metadata: metadata}, kind)

      [_, name, type_spec, desc] ->
        {type, metadata} = parse_type(spec, type_spec, position + byte_size(name) + 1)
        Field.new(%{name: name, type: type, desc: desc, metadata: metadata}, kind)

      _other ->
        raise Imp.Signature.ParseError,
          input: spec,
          position: position,
          detail: "expected `name`, `name: type`, or `name: type \"description\"`"
    end
  end

  defp parse_type(spec, raw, position) do
    raw = String.trim(raw)

    cond do
      Map.has_key?(@types, raw) ->
        {Map.fetch!(@types, raw), %{}}

      Map.has_key?(@answer_shapes, raw) ->
        {:string, %{constraints: %{answer_shape: Map.fetch!(@answer_shapes, raw)}}}

      raw == "array" ->
        {:array, %{}}

      String.starts_with?(raw, "array[") and String.ends_with?(raw, "]") ->
        # Strip EXACTLY ONE `array[...]` layer. `String.trim_leading/2` and
        # `String.trim_trailing/2` remove ALL repeated occurrences, which
        # collapsed `array[array[integer]]` to inner `"integer"` and silently
        # flattened the type (dee-68oy). replace_prefix/replace_suffix remove a
        # single occurrence, so the inner `array[integer]` survives to recurse.
        inner =
          raw
          |> String.replace_prefix("array[", "")
          |> String.replace_suffix("]", "")
          |> String.trim()

        {item_type, item_metadata} = parse_type(spec, inner, position + 6)
        {:array, %{constraints: %{items: item_descriptor(item_type, item_metadata)}}}

      (String.starts_with?(raw, "enum[") or String.starts_with?(raw, "class[")) and
          String.ends_with?(raw, "]") ->
        values =
          raw
          |> String.replace_prefix("enum[", "")
          |> String.replace_prefix("class[", "")
          |> String.trim_trailing("]")
          |> String.split([",", "|"], trim: true)
          |> Enum.map(&String.trim/1)

        {:string, %{constraints: %{enum: values}}}

      true ->
        {suggestion, note} = suggest_type(raw)

        raise Imp.Signature.ParseError,
          input: spec,
          position: position,
          detail: "unknown field type #{inspect(raw)}",
          suggestion: suggestion,
          note: note
    end
  end

  # The `items` descriptor for an array's element type: a FLAT map of the
  # element's type plus its own inline constraint keys (`items` for a nested
  # array, `enum` for a literal, etc.), matching the shape Imp.Schema.json_nested
  # already recurses over. A scalar element yields `%{type: :integer}` exactly as
  # before (backward compatible); a nested `array[integer]` element yields
  # `%{type: :array, items: %{type: :integer}}` (dee-68oy).
  defp item_descriptor(item_type, item_metadata) do
    inner_constraints = Map.get(item_metadata, :constraints, %{})
    Map.merge(%{type: item_type}, inner_constraints)
  end

  defp split_fields(raw) do
    raw
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce({[], "", 0, false, 0}, fn
      {"\"", index}, {fields, current, depth, false, start} ->
        {fields, current <> "\"", depth, true, start || index}

      {"\"", _index}, {fields, current, depth, true, start} ->
        {fields, current <> "\"", depth, false, start}

      {"[", _index}, {fields, current, depth, quoted?, start} ->
        {fields, current <> "[", depth + 1, quoted?, start}

      {"]", _index}, {fields, current, depth, quoted?, start} ->
        {fields, current <> "]", max(depth - 1, 0), quoted?, start}

      {",", index}, {fields, current, 0, false, start} ->
        {[{current, start} | fields], "", 0, false, index + 1}

      {char, index}, {fields, "", depth, quoted?, nil} ->
        {fields, char, depth, quoted?, index}

      {char, _index}, {fields, current, depth, quoted?, start} ->
        {fields, current <> char, depth, quoted?, start}
    end)
    |> then(fn {fields, current, _depth, _quoted?, start} ->
      Enum.reverse([{current, start || 0} | fields])
    end)
  end

  @list_note "(Imp uses array[...] where DSPy uses list[...])"

  # DSPy users reach for Python's `list[...]` / `List[...]`; Imp spells the same
  # thing `array[...]`. Point them at the array form explicitly instead of at the
  # nearest scalar, which is never what they meant. Genuinely unknown scalars still
  # fall through to `closest_type/1`.
  defp suggest_type(raw) do
    case Regex.run(~r/^[Ll]ist\s*\[(.*)\]$/, raw) do
      [_, inner] ->
        inner = String.trim(inner)
        suggestion = if inner == "", do: "array", else: "array[#{inner}]"
        {suggestion, @list_note}

      nil ->
        if raw in ["list", "List"] do
          {"array", @list_note}
        else
          {closest_type(raw), nil}
        end
    end
  end

  defp closest_type(raw) do
    ((@types |> Map.keys()) ++ Map.keys(@answer_shapes))
    |> Enum.max_by(&String.jaro_distance(raw, &1))
  end
end
