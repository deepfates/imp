defmodule Imp.Adapter.CompositeType do
  @moduledoc false

  # Byte-faithful rendering for the non-scalar field types Imp's signature parser
  # models (lib/imp/signature/parser.ex):
  #
  #   * `enum[a,b]` / `class[a,b]` -> `:string` with `constraints.enum` -> DSPy `Literal[...]`
  #   * `array[T]`                 -> `:array`  with `constraints.items`  -> DSPy `list[...]`
  #   * `object` / `map`           -> `:object` -> DSPy `dict[str, Any]`
  #
  # Array item types recurse (dee-68oy / dee-p1d5): `array[array[integer]]` ->
  # `list[list[int]]` and `array[object]` -> `list[dict[str, Any]]`, each with the
  # correspondingly nested JSON-schema note. Mirrors DSPy 3.2.1
  # `dspy/adapters/utils.py` `get_annotation_name` and `translate_field_type`
  # (verified byte-for-byte against the differential runner). Scalars are
  # intentionally NOT handled here; each adapter keeps its own scalar clauses so
  # scalar rendering is untouched. (epic dee-8zev / dee-9ttv)

  @doc """
  DSPy annotation name for a composite field, or `nil` when the field is a scalar
  the caller must render itself.
  """
  def annotation_name(field) do
    node = field_node(field)

    case classify(node) do
      :scalar -> nil
      _ -> annotation_of(node)
    end
  end

  @doc """
  The `translate_field_type` note DESC for a composite field (the text that follows
  "the value you produce "), or `nil` for scalars.
  """
  def note_desc(field) do
    node = field_node(field)

    case classify(node) do
      :scalar ->
        nil

      {:literal, values} ->
        "must exactly match (no extra characters) one of: " <> Enum.join(values, "; ")

      _composite ->
        "must adhere to the JSON schema: " <> schema_of(node)
    end
  end

  @doc """
  The pydantic JSON-schema *property body* (a MAP, no `"title"`) that DSPy's
  `_get_structured_outputs_response_format` emits for this field, POST the
  `enforce_required` rewrite — the per-field value under `properties`. Returns:

    * `:scalar`     — the field is a scalar; the caller supplies the scalar body
      (`Imp.Adapter.JSON` keeps its own scalar type map).
    * `:open_ended` — the field is an open-ended mapping (`dict`/`object`);
      Structured Outputs forbid it, so the caller must fall back to json_object
      (mirrors DSPy `_has_open_ended_mapping` / the `except` fallback).
    * `{:ok, map}`  — the full pydantic body for a `list[...]` or `Literal[...]`.

  Raises for a `Literal` nested inside an array (same reason as `schema_of/1`);
  the caller catches it and falls back to json_object exactly as DSPy's
  `except Exception` clause does.
  """
  def pydantic_schema_body(field) do
    node = field_node(field)

    case classify(node) do
      :scalar -> :scalar
      :dict -> :open_ended
      {:literal, values} -> {:ok, %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}}
      {:list, _item} -> {:ok, list_body(node)}
    end
  end

  # Top-level `list[...]` body. A bare `array` (no item type) mirrors pydantic's
  # `{"items": {}, "type": "array"}`.
  defp list_body(node) do
    case classify(node) do
      {:list, nil} -> %{"type" => "array", "items" => %{}}
      {:list, item} -> %{"type" => "array", "items" => item_body(item)}
    end
  end

  # The pydantic body for a list ELEMENT (recursive; never carries a title).
  defp item_body(node) do
    case classify(node) do
      :scalar ->
        %{"type" => json_schema_type(node.type)}

      {:list, _} ->
        list_body(node)

      :dict ->
        # `list[dict[str, Any]]` element after enforce_required: an object with
        # no declared properties (dee-p1d5 at the json_schema tier).
        %{
          "additionalProperties" => false,
          "properties" => %{},
          "required" => [],
          "type" => "object"
        }

      {:literal, values} ->
        raise ArgumentError,
              "cannot faithfully render the json_schema body for a Literal nested in an array " <>
                "(values: #{inspect(values)}); Imp's array item model has no enum-schema slot."
    end
  end

  # ------------------------------------------------------------------
  # Type nodes: `%{type: t, constraints: c}`. The top-level node comes from the
  # field; an array item node comes from the flat `items` descriptor the parser
  # builds. Both annotation and schema recurse over nodes.

  defp field_node(field), do: %{type: field.type, constraints: constraints(field)}

  defp classify(%{type: type, constraints: constraints}) do
    cond do
      normalize_type(type) == :string and is_list(enum_values(constraints)) ->
        {:literal, enum_values(constraints)}

      normalize_type(type) == :array ->
        {:list, item_node(constraints)}

      normalize_type(type) == :object ->
        :dict

      true ->
        :scalar
    end
  end

  # DSPy get_annotation_name over a node (recursive for nested lists).
  defp annotation_of(node) do
    case classify(node) do
      {:literal, values} ->
        "Literal[" <> Enum.map_join(values, ", ", &quoted_literal/1) <> "]"

      {:list, nil} ->
        "list"

      {:list, item} ->
        "list[" <> annotation_of(item) <> "]"

      :dict ->
        "dict[str, Any]"

      :scalar ->
        python_name(node.type)
    end
  end

  # pydantic `_get_json_schema` fragment over a node (recursive for nested lists).
  defp schema_of(node) do
    case classify(node) do
      {:list, nil} ->
        ~s({"type": "array", "items": {}})

      {:list, item} ->
        ~s({"type": "array", "items": ) <> schema_of(item) <> "}"

      :dict ->
        ~s({"type": "object", "additionalProperties": true})

      :scalar ->
        ~s({"type": ") <> json_schema_type(node.type) <> ~s("})

      {:literal, values} ->
        # A Literal nested inside an array (`array[enum[...]]`) would need
        # pydantic's enum JSON-schema block, which Imp's item model does not
        # carry. Rather than emit a wrong schema, fail loudly (nothing-silent /
        # fidelity-invariant law). Standalone enums never reach schema_of — they
        # take note_desc's {:literal} branch. (dee-p1d5)
        raise ArgumentError,
              "cannot faithfully render the JSON schema for a Literal nested in an array " <>
                "(values: #{inspect(values)}); Imp's array item model has no enum-schema slot. " <>
                "Faithful DSPy output would require the pydantic Literal schema block."
    end
  end

  # ------------------------------------------------------------------

  defp constraints(%{metadata: metadata}) when is_map(metadata),
    do: fetch(metadata, :constraints) || %{}

  defp constraints(_field), do: %{}

  defp enum_values(constraints) when is_map(constraints), do: fetch(constraints, :enum)
  defp enum_values(_constraints), do: nil

  # The array's element type as a node, or nil for a bare `array` (no item type).
  defp item_node(constraints) when is_map(constraints) do
    case fetch(constraints, :items) do
      items when is_map(items) ->
        %{type: fetch(items, :type), constraints: Map.drop(items, [:type, "type"])}

      _other ->
        nil
    end
  end

  defp item_node(_constraints), do: nil

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
      "array" -> :array
      "object" -> :object
      "map" -> :object
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
