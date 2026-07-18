defmodule Imp.Adapter.CompositeType do
  @moduledoc false

  # Byte-faithful rendering for the non-scalar field types Imp's signature parser
  # models (lib/imp/signature/parser.ex):
  #
  #   * `enum[a,b]` / `class[a,b]` -> `:string` with `constraints.enum` -> DSPy `Literal[...]`
  #   * `array[T]`                 -> `:array`  with `constraints.items.type` -> DSPy `list[...]`
  #   * `object` / `map`           -> `:object` -> DSPy `dict[str, Any]`
  #
  # Mirrors DSPy 3.2.1 `dspy/adapters/utils.py` `get_annotation_name` and
  # `translate_field_type` for exactly these composites (verified byte-for-byte
  # against the differential runner). Scalars are intentionally NOT handled here;
  # each adapter keeps its own scalar clauses so scalar rendering is untouched.
  # (epic dee-8zev / dee-9ttv)

  @doc """
  DSPy annotation name for a composite field, or `nil` when the field is a scalar
  the caller must render itself.
  """
  def annotation_name(field) do
    case classify(field) do
      {:literal, values} ->
        "Literal[" <> Enum.map_join(values, ", ", &quoted_literal/1) <> "]"

      {:list, item} ->
        "list" <> list_annotation_args(item)

      :dict ->
        "dict[str, Any]"

      nil ->
        nil
    end
  end

  @doc """
  The `translate_field_type` note DESC for a composite field (the text that follows
  "the value you produce "), or `nil` for scalars.
  """
  def note_desc(field) do
    case classify(field) do
      {:literal, values} ->
        "must exactly match (no extra characters) one of: " <> Enum.join(values, "; ")

      {:list, item} ->
        ~s(must adhere to the JSON schema: {"type": "array", "items": ) <>
          item_schema(item) <> "}"

      :dict ->
        ~s(must adhere to the JSON schema: {"type": "object", "additionalProperties": true})

      nil ->
        nil
    end
  end

  # ------------------------------------------------------------------

  defp classify(field) do
    constraints = constraints(field)

    cond do
      field.type == :string and is_list(enum_values(constraints)) ->
        {:literal, enum_values(constraints)}

      field.type == :array ->
        {:list, item_type(constraints)}

      field.type == :object ->
        :dict

      true ->
        nil
    end
  end

  defp constraints(%{metadata: metadata}) when is_map(metadata),
    do: fetch(metadata, :constraints) || %{}

  defp constraints(_field), do: %{}

  defp enum_values(constraints) when is_map(constraints), do: fetch(constraints, :enum)
  defp enum_values(_constraints), do: nil

  defp item_type(constraints) when is_map(constraints) do
    case fetch(constraints, :items) do
      items when is_map(items) -> fetch(items, :type)
      _other -> nil
    end
  end

  defp item_type(_constraints), do: nil

  # `list[<inner>]`; bare `array` (no item type) -> `list`.
  defp list_annotation_args(nil), do: ""
  defp list_annotation_args(item), do: "[" <> python_name(item) <> "]"

  # JSON-schema fragment for the array's item type; bare `array` -> `{}`.
  defp item_schema(nil), do: "{}"
  defp item_schema(item), do: ~s({"type": ") <> json_schema_type(item) <> ~s("})

  # DSPy get_annotation_name for the scalar Python types Imp's item types map to.
  defp python_name(type) do
    case normalize_type(type) do
      :string -> "str"
      :integer -> "int"
      :float -> "float"
      :number -> "float"
      :boolean -> "bool"
      other -> to_string(other)
    end
  end

  # pydantic JSON-schema `type` keyword for the same scalar item types.
  defp json_schema_type(type) do
    case normalize_type(type) do
      :string -> "string"
      :integer -> "integer"
      :float -> "number"
      :number -> "number"
      :boolean -> "boolean"
      other -> to_string(other)
    end
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    case type do
      "string" -> :string
      "integer" -> :integer
      "int" -> :integer
      "float" -> :float
      "number" -> :number
      "boolean" -> :boolean
      "bool" -> :boolean
      other -> other
    end
  end

  defp normalize_type(type), do: type

  # DSPy utils._quoted_string_for_literal_type_annotation.
  defp quoted_literal(value) do
    s = to_string(value)
    has_single = String.contains?(s, "'")
    has_double = String.contains?(s, "\"")

    cond do
      has_single and not has_double -> ~s("#{s}")
      has_double and not has_single -> "'#{s}'"
      has_single and has_double -> "'" <> String.replace(s, "'", "\\'") <> "'"
      true -> "'#{s}'"
    end
  end

  # Constraints keys arrive as atoms from the parser but may be strings after a
  # metadata round-trip through JSON; accept either.
  defp fetch(map, key) when is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
