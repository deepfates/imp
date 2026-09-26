defmodule Imp.FieldMap do
  @moduledoc """
  Internal. The field maps of `Imp.Example` and `Imp.Prediction`, and the one
  place signature field names are compared.

  A key keeps the type it was given: an atom stays an atom and a string stays a
  string, whatever atoms happen to exist in the VM. Every lookup compares keys
  by their text, so `:answer` finds a field stored under `"answer"` and the
  other way round. No string is ever turned into a new atom.
  """

  @doc "Builds a field map from a map or a list of `{key, value}` pairs."
  def new!(fields, context, owner) when is_map(fields) or is_list(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, acc ->
        put(acc, key!(key, owner), value)

      entry, _acc ->
        raise ArgumentError,
              "#{context} expects fields as {key, value} pairs; got entry: #{inspect(entry)}"
    end)
  end

  @doc "Validates one key: an atom or a string."
  def key!(key, _owner) when is_atom(key) or is_binary(key), do: key

  def key!(key, owner) do
    raise ArgumentError, "#{owner} keys must be atoms or strings; got: #{inspect(key)}"
  end

  @doc "Fetches a field by the text of its key."
  def fetch(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, _value} = found -> found
      :error -> fetch_other(fields, key)
    end
  end

  @doc "Whether a field is stored under either spelling of `key`."
  def has_key?(fields, key), do: match?({:ok, _value}, fetch(fields, key))

  @doc "Gets a field by the text of its key, or `default`."
  def get(fields, key, default \\ nil) do
    case fetch(fields, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Whether two field names have the same text."
  def same_name?(left, right)
      when (is_atom(left) or is_binary(left)) and (is_atom(right) or is_binary(right)),
      do: to_string(left) == to_string(right)

  def same_name?(_left, _right), do: false

  @doc "Whether two lists of field names have the same texts in the same order."
  def same_names?(left, right),
    do:
      length(left) == length(right) and
        Enum.all?(Enum.zip(left, right), fn {l, r} -> same_name?(l, r) end)

  @doc "The name in `names` with the same text as `name`, or `nil`."
  def find_name(names, name), do: Enum.find(names, &same_name?(&1, name))

  @doc "Sets a field. A field already stored under the other spelling keeps its key."
  def put(fields, key, value), do: Map.put(fields, stored_key(fields, key), value)

  @doc "Removes a field under either spelling."
  def delete(fields, key), do: fields |> Map.delete(key) |> Map.delete(other(key))

  @doc "Keeps only the fields whose keys match `keys` by text."
  def take(fields, keys) do
    texts = MapSet.new(keys, &to_string/1)
    Map.filter(fields, fn {key, _value} -> MapSet.member?(texts, to_string(key)) end)
  end

  @doc "Removes the fields whose keys match `keys` by text."
  def drop(fields, keys) do
    texts = MapSet.new(keys, &to_string/1)
    Map.reject(fields, fn {key, _value} -> MapSet.member?(texts, to_string(key)) end)
  end

  defp fetch_other(fields, key) do
    case other(key) do
      nil -> :error
      other -> Map.fetch(fields, other)
    end
  end

  defp stored_key(fields, key) do
    other = other(key)

    if not Map.has_key?(fields, key) and other != nil and Map.has_key?(fields, other),
      do: other,
      else: key
  end

  # The same text under the other type. A string whose atom does not exist has
  # no atom spelling, and none is created for it.
  defp other(key) when is_atom(key), do: Atom.to_string(key)

  defp other(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp other(_key), do: nil
end
