defmodule Imp.Signature.Field do
  @moduledoc "Metadata for one signature field."

  @enforce_keys [:name, :kind]
  defstruct [:name, :kind, type: :string, desc: nil, prefix: nil, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom() | String.t(),
          kind: :input | :output,
          type: atom() | String.t(),
          desc: String.t() | nil,
          prefix: String.t() | nil,
          metadata: map()
        }

  def new(%__MODULE__{} = field, _kind), do: field

  def new({name, opts}, kind) when is_list(opts) or is_map(opts),
    do: new(Map.put(Map.new(opts), :name, name), kind)

  def new({_name, opts}, _kind) do
    raise ArgumentError,
          "Imp.Signature.Field.new/2 expects field options as a map or keyword list, got: #{inspect(opts)}"
  end

  def new(%{} = attrs, kind) do
    name = attrs |> Map.get(:name, Map.get(attrs, "name")) |> normalize_name()

    %__MODULE__{
      name: name,
      kind: attrs |> Map.get(:kind, Map.get(attrs, "kind", kind)) |> normalize_kind(),
      type: attrs |> Map.get(:type, Map.get(attrs, "type", :string)) |> normalize_type(),
      desc: Map.get(attrs, :desc, Map.get(attrs, "desc")),
      prefix: Map.get(attrs, :prefix, Map.get(attrs, "prefix", infer_prefix(name))),
      metadata: metadata(attrs)
    }
  end

  def new(name, kind) when is_atom(name) do
    %__MODULE__{name: name, kind: normalize_kind(kind), prefix: infer_prefix(name)}
  end

  def new(name, kind) when is_binary(name) do
    {name, type} = parse_name_and_type(name)
    name = normalize_name(name)
    %__MODULE__{name: name, kind: normalize_kind(kind), type: type, prefix: infer_prefix(name)}
  end

  def new(name, _kind) do
    raise ArgumentError,
          "Imp.Signature.Field.new/2 expects field name or map to use an atom or string name, got: #{inspect(name)}"
  end

  def dump(%__MODULE__{} = field) do
    %{
      "name" => to_string(field.name),
      "kind" => Atom.to_string(field.kind),
      "type" => to_string(field.type),
      "desc" => field.desc,
      "prefix" => field.prefix,
      "metadata" => field.metadata
    }
  end

  def load(map), do: new(map, map["kind"])

  def constrained(%__MODULE__{} = field, constraints) do
    %__MODULE__{field | metadata: Map.put(field.metadata, :constraints, constraints)}
  end

  def optional(%__MODULE__{} = field),
    do: %__MODULE__{field | metadata: Map.put(field.metadata, :optional, true)}

  defp metadata(attrs) do
    metadata = Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    constraints = Map.get(attrs, :constraints, Map.get(attrs, "constraints"))

    metadata =
      if constraints do
        Map.put(metadata, :constraints, constraints)
      else
        metadata
      end

    # DSPy InputField(default=...): an input field may carry a default value
    # that fills the input when the caller omits it (Predict fills it before
    # the missing-field check; test_input_field_default_value). Key presence,
    # not truthiness, decides — an explicit nil default is a real default.
    case fetch_default(attrs) do
      {:ok, default} -> Map.put(metadata, :default, default)
      :error -> metadata
    end
  end

  defp fetch_default(attrs) do
    case Map.fetch(attrs, :default) do
      {:ok, default} -> {:ok, default}
      :error -> Map.fetch(attrs, "default")
    end
  end

  defp normalize_name(name) when is_atom(name), do: name

  defp normalize_name(name) when is_binary(name),
    do: name |> String.trim() |> existing_atom_or_string()

  defp normalize_name(name) do
    raise ArgumentError,
          "Imp.Signature.Field.new/2 expects field name to be an atom or string, got: #{inspect(name)}"
  end

  defp normalize_kind(kind) when kind in [:input, :output], do: kind
  defp normalize_kind("input"), do: :input
  defp normalize_kind("output"), do: :output

  defp normalize_kind(kind),
    do:
      raise(
        ArgumentError,
        "Imp.Signature.Field.new/2 expects kind to be :input or :output, got: #{inspect(kind)}"
      )

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: normalize_type_alias(type)

  defp normalize_type(type) do
    raise ArgumentError,
          "Imp.Signature.Field.new/2 expects field type to be an atom or string, got: #{inspect(type)}"
  end

  defp parse_name_and_type(raw) do
    case String.split(raw, ":", parts: 2) do
      [name, type] -> {String.trim(name), type |> String.trim() |> normalize_type_alias()}
      [name] -> {String.trim(name), :string}
    end
  end

  defp normalize_type_alias("str"), do: :string
  defp normalize_type_alias("string"), do: :string
  defp normalize_type_alias("int"), do: :integer
  defp normalize_type_alias("integer"), do: :integer
  defp normalize_type_alias("float"), do: :float
  defp normalize_type_alias("number"), do: :number
  defp normalize_type_alias("bool"), do: :boolean
  defp normalize_type_alias("boolean"), do: :boolean
  defp normalize_type_alias("datetime"), do: :datetime
  defp normalize_type_alias(other), do: existing_atom_or_string(other)

  # Faithful port of DSPy `infer_prefix` (dspy/signatures/signature.py):
  # camelCase and digit boundaries become underscores, then each word is
  # title-cased with all-caps acronyms preserved ("someAttributeName42IsCool"
  # -> "Some Attribute Name 42 Is Cool", "isHTTPSecure" -> "Is HTTP Secure").
  # The trailing ":" is Imp's prefix convention (DSPy appends it at the
  # InputField/OutputField default). (dee-1nkd)
  defp infer_prefix(name) do
    name
    |> to_string()
    # Step 1: camelCase -> snake_case ("camelCase" -> "camel_Case"), then
    # consecutive capitals ("camel_Case" -> "camel_case" boundaries).
    |> then(&Regex.replace(~r/(.)([A-Z][a-z]+)/, &1, "\\1_\\2"))
    |> then(&Regex.replace(~r/([a-z0-9])([A-Z])/, &1, "\\1_\\2"))
    # Step 2: underscores around digit runs ("text2number" -> "text_2_number").
    |> then(&Regex.replace(~r/([A-Za-z])(\d)/, &1, "\\1_\\2"))
    |> then(&Regex.replace(~r/(\d)([A-Za-z])/, &1, "\\1_\\2"))
    # Step 3: Title Case per word, preserving acronyms (Python str.isupper()).
    |> String.split("_")
    |> Enum.map_join(" ", fn word ->
      if python_isupper?(word), do: word, else: String.capitalize(word)
    end)
    |> Kernel.<>(":")
  end

  # Python `str.isupper/0`: at least one cased character and no lowercase ones.
  defp python_isupper?(word) do
    String.match?(word, ~r/\p{Lu}/u) and not String.match?(word, ~r/\p{Ll}/u)
  end

  defp existing_atom_or_string(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
