defmodule Imp.Adapter.FieldType do
  @moduledoc false

  # How a field's type is put into words for a model, declared once. Every
  # adapter (Chat, JSON, XML, TwoStep through Chat, SingleField) and the
  # ReAct loops render type wording from this module, and `Imp.Schema` and
  # `Imp.Adapter.JSON` take their JSON-schema `type` keywords from it.
  #
  # The wording names no programming language: a model reading an Imp prompt
  # sees "integer", "true or false" or "one of: a, b", not a host language's
  # type spelling. DSPy parity means the same fields, order, constraints and
  # parse results, not the same text (`decisions.md`).
  #
  # A type is a node `%{type: t, constraints: c}`. The signature parser models
  # `enum[a,b]` as `:string` with `constraints.enum`, `array[T]` as `:array`
  # with `constraints.items`, and `object`/`map` as `:object`; array items
  # recurse.

  # type => {label, with an article, plural}
  @words %{
    string: {"string", "a string", "strings"},
    integer: {"integer", "an integer", "integers"},
    float: {"number", "a number", "numbers"},
    number: {"number", "a number", "numbers"},
    boolean: {"true or false", "true or false", "true-or-false values"},
    datetime: {"ISO 8601 date and time", "an ISO 8601 date and time", "ISO 8601 dates and times"},
    object: {"object", "an object", "objects"}
  }

  # type => the note after "the value you produce " for a scalar output field
  @notes %{
    integer: "must be a single integer",
    float: "must be a single number",
    number: "must be a single number",
    boolean: "must be true or false"
  }

  # type => JSON-schema `type` keyword; any other type travels as a string
  @json_types %{
    string: "string",
    integer: "integer",
    float: "number",
    number: "number",
    boolean: "boolean",
    array: "array",
    object: "object",
    null: "null"
  }

  @doc """
  The field's type as a noun phrase, for a field listing:
  `string`, `one of: atlas, harbor`, `list of integers`.
  """
  def label(field) do
    if code?(field), do: "code in #{code_language(field)}", else: label_of(field_node(field))
  end

  @doc """
  What a value of the field's type must be, after "must be formatted as ", or
  `nil` for text, which needs no formatting.
  """
  def requirement(field) do
    cond do
      code?(field) -> "code in #{code_language(field)}"
      text?(field_node(field)) -> nil
      true -> requirement_of(field_node(field))
    end
  end

  @doc """
  The note that follows "the value you produce " in an output field's
  placeholder, or `nil` when the type needs none.
  """
  def note(field) do
    node = field_node(field)

    case classify(node) do
      {:enum, values} ->
        "must exactly match (no extra characters) one of: " <>
          Enum.map_join(values, "; ", &member/1)

      {:list, _item} ->
        "must adhere to the JSON schema: " <> schema_text(node)

      :object ->
        "must adhere to the JSON schema: " <> schema_text(node)

      _other ->
        Map.get(@notes, normalize_type(node.type))
    end
  end

  @doc """
  A field's placeholder in the interaction template: `{name}`, and for an
  output field whose type has a note, the note after eight spaces.
  """
  def placeholder(field, :input), do: "{#{field.name}}"

  def placeholder(field, :output) do
    case note(field) do
      nil ->
        "{#{field.name}}"

      note ->
        "{#{field.name}}" <> String.duplicate(" ", 8) <> "# note: the value you produce " <> note
    end
  end

  @doc "The JSON-schema `type` keyword for a scalar type."
  def json_type(type), do: Map.get(@json_types, normalize_type(type), "string")

  @doc """
  The structured-output property body (no `"title"`) for an output field:

    * `:scalar` — the caller supplies `%{"type" => json_type(type)}`.
    * `:open_ended` — an open-ended object, which structured outputs forbid.
    * `{:ok, map}` — the body for a list or an enum.

  Raises for an enum nested in a list, which the array item model cannot
  express; the caller falls back to plain JSON mode.
  """
  def json_schema_body(field) do
    node = field_node(field)

    case classify(node) do
      {:enum, values} -> {:ok, %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}}
      {:list, _item} -> {:ok, list_body(node)}
      :object -> :open_ended
      _scalar -> :scalar
    end
  end

  # ------------------------------------------------------------------

  defp label_of(node) do
    case classify(node) do
      {:enum, values} -> "one of: " <> Enum.map_join(values, ", ", &member/1)
      {:list, nil} -> "list"
      {:list, item} -> "list of " <> plural_of(item)
      {:union, branches} -> Enum.map_join(branches, " or ", &label_of/1)
      _other -> words(node.type, 0)
    end
  end

  defp requirement_of(node) do
    case classify(node) do
      {:enum, _values} -> label_of(node)
      {:list, _item} -> "a " <> label_of(node)
      {:union, branches} -> Enum.map_join(branches, " or ", &requirement_of/1)
      _other -> words(node.type, 1)
    end
  end

  defp plural_of(node) do
    case classify(node) do
      {:enum, values} -> "values, each one of: " <> Enum.map_join(values, ", ", &member/1)
      {:list, nil} -> "lists"
      {:list, item} -> "lists of " <> plural_of(item)
      {:union, branches} -> Enum.map_join(branches, " or ", &plural_of/1)
      _other -> words(node.type, 2)
    end
  end

  defp words(type, form) do
    case Map.fetch(@words, normalize_type(type)) do
      {:ok, forms} -> elem(forms, form)
      :error -> to_string(type)
    end
  end

  defp text?(node), do: classify(node) == :scalar and normalize_type(node.type) == :string

  # An enum member as the model should write it. A string that the list
  # separators would make ambiguous is quoted; any other value takes its JSON
  # spelling (true, 3, null).
  defp member(value) when is_binary(value) do
    if value == "" or String.trim(value) != value or String.contains?(value, [",", ";"]),
      do: Jason.encode!(value),
      else: value
  end

  defp member(value), do: Jason.encode!(value)

  defp list_body(node) do
    case classify(node) do
      {:list, nil} -> %{"type" => "array", "items" => %{}}
      {:list, item} -> %{"type" => "array", "items" => item_body(item)}
    end
  end

  defp item_body(node) do
    case classify(node) do
      {:list, _} ->
        list_body(node)

      :object ->
        %{
          "additionalProperties" => false,
          "properties" => %{},
          "required" => [],
          "type" => "object"
        }

      {:enum, values} ->
        raise ArgumentError,
              "cannot render a structured-output schema for an enum nested in a list " <>
                "(values: #{inspect(values)}); the array item model has no enum slot."

      _scalar ->
        %{"type" => json_type(node.type)}
    end
  end

  defp schema_text(node) do
    case classify(node) do
      {:list, nil} ->
        ~s({"type": "array", "items": {}})

      {:list, item} ->
        ~s({"type": "array", "items": ) <> schema_text(item) <> "}"

      :object ->
        ~s({"type": "object", "additionalProperties": true})

      {:enum, values} ->
        ~s({"type": "string", "enum": ) <>
          Imp.Adapter.Chat.format_value(Enum.to_list(values)) <> "}"

      _scalar ->
        ~s({"type": ") <> json_type(node.type) <> ~s("})
    end
  end

  # ------------------------------------------------------------------

  defp field_node(field), do: %{type: field.type, constraints: constraints(field)}

  defp classify(%{type: type, constraints: constraints}) do
    case normalize_type(type) do
      :string ->
        case enum_values(constraints) do
          values when is_list(values) -> {:enum, values}
          _none -> :scalar
        end

      :array ->
        {:list, item_node(constraints)}

      :object ->
        :object

      :union ->
        {:union, union_nodes(constraints)}

      _other ->
        :scalar
    end
  end

  defp constraints(%{metadata: metadata}) when is_map(metadata),
    do: fetch(metadata, :constraints) || %{}

  defp constraints(_field), do: %{}

  defp enum_values(constraints) when is_map(constraints), do: fetch(constraints, :enum)
  defp enum_values(_constraints), do: nil

  defp item_node(constraints) when is_map(constraints) do
    case fetch(constraints, :items) do
      items when is_map(items) ->
        %{type: fetch(items, :type), constraints: Map.drop(items, [:type, "type"])}

      _other ->
        nil
    end
  end

  defp item_node(_constraints), do: nil

  defp union_nodes(constraints) when is_map(constraints) do
    constraints
    |> fetch(:any_of)
    |> List.wrap()
    |> Enum.map(fn branch ->
      %{type: fetch(branch, :type) || :string, constraints: Map.drop(branch, [:type, "type"])}
    end)
  end

  defp union_nodes(_constraints), do: []

  defp code?(%{type: type}), do: type in [:code, "code"]

  defp code_language(field) do
    field.metadata
    |> fetch(:language)
    |> Kernel.||("python")
    |> to_string()
  end

  defp normalize_type(type) when type in [:reasoning, "reasoning", "str"], do: :string
  defp normalize_type(type) when type in ["int"], do: :integer
  defp normalize_type(type) when type in ["bool"], do: :boolean
  defp normalize_type(type) when type in ["map"], do: :object

  defp normalize_type(type) when is_binary(type) do
    case Enum.find(Map.keys(@json_types) ++ [:datetime, :union], &(Atom.to_string(&1) == type)) do
      nil -> type
      atom -> atom
    end
  end

  defp normalize_type(type), do: type

  # Keys arrive as atoms from the parser and as strings after a JSON round trip.
  defp fetch(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp fetch(_map, _key), do: nil
end
