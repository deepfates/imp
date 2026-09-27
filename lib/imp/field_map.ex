defmodule Imp.FieldMap do
  @moduledoc """
  Internal. The field maps of `Imp.Example` and `Imp.Prediction`, and the one
  place signature field names are compared.

  A key keeps the type it was given: an atom stays an atom and a string stays a
  string, whatever atoms happen to exist in the VM. Every lookup compares keys
  by their text, so `:answer` finds a field stored under `"answer"` and the
  other way round. No string is ever turned into a new atom.
  """

  @doc """
  Builds a field map from a map or a list of `{key, value}` pairs.

  Raises `ArgumentError` when two entries name the same field, as `:answer` and
  `"answer"` do: keeping one would silently drop the other's value.
  """
  def new!(fields, context, owner) when is_map(fields) or is_list(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, acc ->
        key = key!(key, owner)

        if has_key?(acc, key) do
          raise ArgumentError,
                "#{context} got the field #{inspect(to_string(key))} more than once " <>
                  "(as an atom and a string, or repeated); give each field once"
        end

        put(acc, key, value)

      entry, _acc ->
        raise ArgumentError,
              "#{context} expects fields as {key, value} pairs; got entry: #{describe(entry)}"
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

  @doc false
  # A term described by its type and, for a map or a field pair list, its key
  # names: never its values, which can be private data. Used in messages about
  # fields, rows and demos.
  def describe(%module{}), do: "a #{inspect(module)} struct"
  def describe(term) when is_map(term), do: "a map with keys #{inspect(key_names(term))}"
  def describe([]), do: "an empty list"

  def describe(term) when is_list(term) do
    if Enum.all?(term, &match?({key, _value} when is_atom(key) or is_binary(key), &1)),
      do: "a field pair list with keys #{inspect(key_names(term))}",
      else: "a list"
  end

  def describe(term) when is_binary(term), do: "a string"
  def describe(term) when is_integer(term), do: "an integer"
  def describe(term) when is_float(term), do: "a float"
  def describe(term) when is_boolean(term) or is_nil(term), do: inspect(term)
  def describe(term) when is_atom(term), do: "an atom"
  def describe(term) when is_tuple(term), do: "a tuple of #{tuple_size(term)} elements"
  def describe(term) when is_function(term), do: "a function"
  def describe(term) when is_pid(term), do: "a pid"
  def describe(_term), do: "a term"

  @doc false
  # The keys of a map, sorted by their text, or of a list's `{key, value}`
  # entries in order.
  def key_names(fields) when is_map(fields),
    do: fields |> Map.keys() |> Enum.sort_by(&key_text/1)

  def key_names(fields) when is_list(fields), do: for({key, _value} <- fields, do: key)

  defp key_text(key) when is_atom(key) or is_binary(key), do: to_string(key)
  defp key_text(key), do: inspect(key)

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
