defmodule DSPy.Signature.Field do
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
  def new({name, opts}, kind), do: new(Map.put(Map.new(opts), :name, name), kind)

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

    if constraints do
      Map.put(metadata, :constraints, constraints)
    else
      metadata
    end
  end

  defp normalize_name(name) when is_atom(name), do: name

  defp normalize_name(name) when is_binary(name),
    do: name |> String.trim() |> existing_atom_or_string()

  defp normalize_kind(kind) when kind in [:input, :output], do: kind
  defp normalize_kind("input"), do: :input
  defp normalize_kind("output"), do: :output
  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: normalize_type_alias(type)

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
  defp normalize_type_alias(other), do: existing_atom_or_string(other)

  defp infer_prefix(name) do
    name
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(":")
  end

  defp existing_atom_or_string(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
