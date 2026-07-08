defmodule DSEx.Example do
  @moduledoc """
  Flexible row of named data used for train/dev/test sets.

  Examples are plain data with one important DSEx convention: call
  `with_inputs/2` to mark which fields a program may see. The remaining fields
  are labels for evaluation, bootstrapping, demonstrations, and optimizers.

  Keys are normalized carefully. Existing atoms stay atoms, existing atom names
  in strings resolve to those atoms, and unknown strings remain strings rather
  than creating atoms from untrusted external data.

  Internal fields whose names start with `dsex_` are omitted from `keys/1`,
  `items/1`, and `values/1`, but `to_map/1` remains lossless for persistence and
  debugging.

  ## Example

      iex> example =
      ...>   DSEx.Example.new(question: "2+2?", answer: "4", dsex_trace: :kept)
      ...>   |> DSEx.Example.with_inputs(:question)
      iex> DSEx.Example.to_map(DSEx.Example.inputs(example))
      %{question: "2+2?"}
      iex> DSEx.Example.to_map(DSEx.Example.labels(example))
      %{answer: "4", dsex_trace: :kept}
      iex> DSEx.Example.keys(example) |> Enum.sort()
      [:answer, :question]
  """

  @type t :: %__MODULE__{fields: map(), input_keys: [atom() | String.t()] | nil, demos: list()}

  defstruct fields: %{}, input_keys: nil, demos: []

  @doc "Builds an example from a map, keyword list, or existing example."
  def new(fields \\ %{})
  def new(%__MODULE__{} = example), do: example

  def new(fields) when is_list(fields) or is_map(fields),
    do: %__MODULE__{fields: normalize_keys(fields)}

  def new(fields) do
    raise ArgumentError,
          "DSEx.Example.new/1 expects a map, keyword list, or DSEx.Example; got: #{inspect(fields)}"
  end

  @doc "Reads a field, returning `default` when it is missing."
  def get(%__MODULE__{fields: fields}, key, default \\ nil),
    do: get_key(fields, normalize_key(key), default)

  @doc "Reads a field or raises `KeyError` when it is missing."
  def fetch!(%__MODULE__{fields: fields}, key) do
    case fetch_key(fields, normalize_key(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  @doc "Returns a copy of the example with one field set."
  def put(%__MODULE__{fields: fields} = example, key, value),
    do: %{example | fields: Map.put(fields, normalize_key(key), value)}

  @doc "Returns a copy of the example with one field removed."
  def delete(%__MODULE__{fields: fields} = example, key),
    do: %{example | fields: delete_key(fields, normalize_key(key))}

  @doc "Returns non-internal field keys."
  def keys(%__MODULE__{fields: fields}), do: Map.keys(fields) |> Enum.reject(&internal?/1)

  @doc "Returns non-internal field values."
  def values(%__MODULE__{} = example), do: example |> items() |> Enum.map(fn {_k, v} -> v end)

  @doc "Returns non-internal `{key, value}` field pairs."
  def items(%__MODULE__{fields: fields}),
    do: fields |> Enum.reject(fn {k, _v} -> internal?(k) end)

  @doc "Returns the full field map, including internal `dsex_` fields."
  def to_map(%__MODULE__{fields: fields}), do: fields

  @doc "Marks which fields are inputs for programs and optimizers."
  def with_inputs(%__MODULE__{} = example, keys),
    do: %{example | input_keys: keys |> List.wrap() |> Enum.map(&normalize_key/1)}

  @doc "Returns an example containing only the marked input fields."
  def inputs(%__MODULE__{input_keys: nil} = example), do: example

  def inputs(%__MODULE__{} = example),
    do: %{example | fields: Map.take(example.fields, example.input_keys)}

  @doc "Returns an example containing label fields, excluding marked inputs."
  def labels(%__MODULE__{input_keys: nil}), do: new(%{})

  def labels(%__MODULE__{} = example),
    do: %{example | fields: Map.drop(example.fields, example.input_keys)}

  @doc "Attaches demonstrations to an example."
  def with_demos(%__MODULE__{} = example, demos), do: %{example | demos: List.wrap(demos)}

  defp normalize_keys(fields), do: Map.new(fields, fn {k, v} -> {normalize_key(k), v} end)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp normalize_key(key) do
    raise ArgumentError,
          "DSEx.Example keys must be atoms or strings; got: #{inspect(key)}"
  end

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
    do: key |> Atom.to_string() |> String.starts_with?("dsex_")

  defp internal?(key) when is_binary(key), do: String.starts_with?(key, "dsex_")
end
