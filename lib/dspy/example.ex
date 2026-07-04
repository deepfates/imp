defmodule DSPy.Example do
  @moduledoc "Flexible row of named data used for train/dev/test sets."

  defstruct fields: %{}, input_keys: nil, demos: []

  def new(fields \\ %{})
  def new(%__MODULE__{} = example), do: example

  def new(fields) when is_list(fields) or is_map(fields),
    do: %__MODULE__{fields: atomize_keys(fields)}

  def get(%__MODULE__{fields: fields}, key, default \\ nil),
    do: Map.get(fields, normalize_key(key), default)

  def fetch!(%__MODULE__{fields: fields}, key), do: Map.fetch!(fields, normalize_key(key))

  def put(%__MODULE__{fields: fields} = example, key, value),
    do: %{example | fields: Map.put(fields, normalize_key(key), value)}

  def delete(%__MODULE__{fields: fields} = example, key),
    do: %{example | fields: Map.delete(fields, normalize_key(key))}

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

  defp atomize_keys(fields), do: Map.new(fields, fn {k, v} -> {normalize_key(k), v} end)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
  defp internal?(key), do: key |> Atom.to_string() |> String.starts_with?("dspy_")
end
