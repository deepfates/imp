defmodule DSPy.Signature.Field do
  @moduledoc "Metadata for one signature field."

  @enforce_keys [:name, :kind]
  defstruct [:name, :kind, type: :string, desc: nil, prefix: nil, metadata: %{}]

  @type t :: %__MODULE__{
          name: atom(),
          kind: :input | :output,
          type: atom(),
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
      metadata: Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    }
  end

  def new(name, kind) when is_atom(name) or is_binary(name) do
    name = normalize_name(name)
    %__MODULE__{name: name, kind: normalize_kind(kind), prefix: infer_prefix(name)}
  end

  def dump(%__MODULE__{} = field) do
    %{
      "name" => Atom.to_string(field.name),
      "kind" => Atom.to_string(field.kind),
      "type" => Atom.to_string(field.type),
      "desc" => field.desc,
      "prefix" => field.prefix,
      "metadata" => field.metadata
    }
  end

  def load(map), do: new(map, map["kind"])

  defp normalize_name(name) when is_atom(name), do: name
  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.to_atom()
  defp normalize_kind(kind) when kind in [:input, :output], do: kind
  defp normalize_kind("input"), do: :input
  defp normalize_kind("output"), do: :output
  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type(type) when is_binary(type), do: String.to_atom(type)

  defp infer_prefix(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
    |> Kernel.<>(":")
  end
end
