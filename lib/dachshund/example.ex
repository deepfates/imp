defmodule Dachshund.Example do
  @moduledoc "Flexible row of named data used for train/dev/test sets."

  @type t :: %__MODULE__{fields: map(), input_keys: [atom() | String.t()] | nil, demos: list()}

  defstruct fields: %{}, input_keys: nil, demos: []

  def new(fields \\ %{})
  def new(%__MODULE__{} = example), do: example

  def new(fields) when is_list(fields) or is_map(fields),
    do: %__MODULE__{fields: normalize_keys(fields)}

  def get(%__MODULE__{fields: fields}, key, default \\ nil),
    do: get_key(fields, normalize_key(key), default)

  def fetch!(%__MODULE__{fields: fields}, key) do
    case fetch_key(fields, normalize_key(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  def put(%__MODULE__{fields: fields} = example, key, value),
    do: %{example | fields: Map.put(fields, normalize_key(key), value)}

  def delete(%__MODULE__{fields: fields} = example, key),
    do: %{example | fields: delete_key(fields, normalize_key(key))}

  def keys(%__MODULE__{fields: fields}), do: Map.keys(fields) |> Enum.reject(&internal?/1)
  def values(%__MODULE__{} = example), do: example |> items() |> Enum.map(fn {_k, v} -> v end)

  def items(%__MODULE__{fields: fields}),
    do: fields |> Enum.reject(fn {k, _v} -> internal?(k) end)

  def to_map(%__MODULE__{fields: fields}), do: fields

  def with_inputs(%__MODULE__{} = example, keys),
    do: %{example | input_keys: keys |> List.wrap() |> Enum.map(&normalize_key/1)}

  def inputs(%__MODULE__{input_keys: nil} = example), do: example

  def inputs(%__MODULE__{} = example),
    do: %{example | fields: Map.take(example.fields, example.input_keys)}

  def labels(%__MODULE__{input_keys: nil}), do: new(%{})

  def labels(%__MODULE__{} = example),
    do: %{example | fields: Map.drop(example.fields, example.input_keys)}

  def with_demos(%__MODULE__{} = example, demos), do: %{example | demos: List.wrap(demos)}

  defp normalize_keys(fields), do: Map.new(fields, fn {k, v} -> {normalize_key(k), v} end)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp get_key(fields, key, default) do
    case fetch_key(fields, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_key(fields, key) do
    cond do
      Map.has_key?(fields, key) ->
        Map.fetch(fields, key)

      is_atom(key) and Map.has_key?(fields, Atom.to_string(key)) ->
        Map.fetch(fields, Atom.to_string(key))

      is_binary(key) ->
        case existing_atom_or_string(key) do
          atom when is_atom(atom) -> Map.fetch(fields, atom)
          _string -> :error
        end

      true ->
        :error
    end
  end

  defp delete_key(fields, key) when is_atom(key),
    do: fields |> Map.delete(key) |> Map.delete(Atom.to_string(key))

  defp delete_key(fields, key) when is_binary(key),
    do: fields |> Map.delete(key) |> Map.delete(existing_atom_or_string(key))

  defp internal?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.starts_with?("dachshund_")

  defp internal?(key) when is_binary(key), do: String.starts_with?(key, "dachshund_")
end
