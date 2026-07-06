defmodule DSEx.Signature.ParseError do
  defexception [:message, :input, :position]

  def exception(opts) do
    input = Keyword.fetch!(opts, :input)
    position = Keyword.fetch!(opts, :position)
    detail = Keyword.fetch!(opts, :detail)
    suggestion = Keyword.get(opts, :suggestion)

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
        if(suggestion, do: "did you mean #{inspect(suggestion)}?", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    %__MODULE__{message: message, input: input, position: position}
  end
end

defmodule DSEx.Signature.Parser do
  @moduledoc false

  alias DSEx.Signature.Field

  @types %{
    "string" => :string,
    "number" => :number,
    "integer" => :integer,
    "int" => :integer,
    "float" => :float,
    "boolean" => :boolean,
    "bool" => :boolean,
    "object" => :object,
    "map" => :object
  }

  def parse(spec) when is_binary(spec) do
    case split_arrow(spec) do
      {:ok, raw_inputs, raw_outputs} ->
        {parse_fields(spec, raw_inputs, :input, 0),
         parse_fields(spec, raw_outputs, :output, arrow_end(spec))}

      :error ->
        raise DSEx.Signature.ParseError,
          input: spec,
          position: max(String.length(spec) - 1, 0),
          detail: "signature must contain exactly one `->`"
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
        raise DSEx.Signature.ParseError,
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

      raw == "array" ->
        {:array, %{}}

      String.starts_with?(raw, "array[") and String.ends_with?(raw, "]") ->
        inner = raw |> String.trim_leading("array[") |> String.trim_trailing("]") |> String.trim()
        {item_type, _metadata} = parse_type(spec, inner, position + 6)
        {:array, %{constraints: %{items: %{type: item_type}}}}

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
        raise DSEx.Signature.ParseError,
          input: spec,
          position: position,
          detail: "unknown field type #{inspect(raw)}",
          suggestion: closest_type(raw)
    end
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

  defp closest_type(raw) do
    @types
    |> Map.keys()
    |> Enum.max_by(&String.jaro_distance(raw, &1))
  end
end
