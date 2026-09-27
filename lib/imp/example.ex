defmodule Imp.Example do
  @moduledoc """
  Flexible row of named data used for train/dev/test sets.

  Examples are plain data with one important Imp convention: call
  `with_inputs/2` to mark which fields a program may see. The remaining fields
  are labels for evaluation, bootstrapping, demonstrations, and optimizers.
  Until inputs are declared, `inputs/1` and `labels/1` raise, since no field
  can be told apart from a label.

  A key keeps the type it was given: `%{"question" => ...}` is stored under the
  string and `%{question: ...}` under the atom, and no string is turned into an
  atom. Every function that takes a key compares keys by their text, so
  `get(example, :question)` reads a field stored under `"question"`, and
  `new/1` refuses a field given under both spellings.

  Internal fields whose names start with `imp_` are omitted from `keys/1`,
  `items/1`, and `values/1`, but `to_map/1` remains lossless for persistence and
  debugging.

  ## Example

      iex> example =
      ...>   Imp.Example.new(question: "2+2?", answer: "4", imp_trace: :kept)
      ...>   |> Imp.Example.with_inputs(:question)
      iex> Imp.Example.to_map(Imp.Example.inputs(example))
      %{question: "2+2?"}
      iex> Imp.Example.to_map(Imp.Example.labels(example))
      %{answer: "4", imp_trace: :kept}
      iex> Imp.Example.keys(example) |> Enum.sort()
      [:answer, :question]
  """

  @type t :: %__MODULE__{fields: map(), input_keys: [atom() | String.t()] | nil, demos: list()}

  defstruct fields: %{}, input_keys: nil, demos: []

  @doc "Builds an example from a map, field pair list, or existing example."
  def new(fields \\ %{})
  def new(%__MODULE__{} = example), do: example

  def new(fields) when is_list(fields) or is_map(fields),
    do: %__MODULE__{fields: Imp.FieldMap.new!(fields, "Imp.Example.new/1", "Imp.Example")}

  def new(fields) do
    raise ArgumentError,
          "Imp.Example.new/1 expects a map, field pair list, or Imp.Example; got: #{inspect(fields)}"
  end

  @doc "Reads a field, returning `default` when it is missing."
  def get(%__MODULE__{fields: fields}, key, default \\ nil) do
    case Imp.FieldMap.fetch(fields, key!(key)) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc "Reads a field or raises `KeyError` when it is missing."
  def fetch!(%__MODULE__{fields: fields}, key) do
    case Imp.FieldMap.fetch(fields, key!(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  @doc "Returns a copy of the example with one field set."
  def put(%__MODULE__{fields: fields} = example, key, value),
    do: %{example | fields: Imp.FieldMap.put(fields, key!(key), value)}

  @doc "Returns a copy of the example with one field removed."
  def delete(%__MODULE__{fields: fields} = example, key),
    do: %{example | fields: Imp.FieldMap.delete(fields, key!(key))}

  @doc "Returns non-internal field keys."
  def keys(%__MODULE__{fields: fields}), do: Map.keys(fields) |> Enum.reject(&internal?/1)

  @doc "Returns non-internal field values."
  def values(%__MODULE__{} = example), do: example |> items() |> Enum.map(fn {_k, v} -> v end)

  @doc "Returns non-internal `{key, value}` field pairs."
  def items(%__MODULE__{fields: fields}),
    do: fields |> Enum.reject(fn {k, _v} -> internal?(k) end)

  @doc "Returns the full field map, including internal `imp_` fields."
  def to_map(%__MODULE__{fields: fields}), do: fields

  @doc "Marks which fields are inputs for programs and optimizers."
  def with_inputs(%__MODULE__{} = example, keys),
    do: %{example | input_keys: keys |> List.wrap() |> Enum.map(&key!/1)}

  @doc """
  Returns an example containing only the marked input fields.

  Raises `ArgumentError` when `with_inputs/2` was never called: without a
  declared split every field, labels included, would reach the program.
  """
  def inputs(%__MODULE__{} = example),
    do: %{example | fields: Imp.FieldMap.take(example.fields, input_keys!(example, "inputs"))}

  @doc """
  Returns an example containing label fields, excluding marked inputs.

  Raises `ArgumentError` when `with_inputs/2` was never called, as `inputs/1`
  does.
  """
  def labels(%__MODULE__{} = example),
    do: %{example | fields: Imp.FieldMap.drop(example.fields, input_keys!(example, "labels"))}

  @doc false
  # Raises the error `inputs/1` would for the first row of `rows` that cannot
  # say which of its fields are inputs. Evaluation and optimizers call it
  # before running anything, outside the per-row recovery that would otherwise
  # record the error as a failed, scored row. A plain map or field pair list
  # cannot declare inputs. Any other row, or a `rows` that is not enumerable,
  # is left to the caller's own checks.
  def require_inputs!(rows) do
    if Enumerable.impl_for(rows), do: Enum.each(rows, &require_row_inputs!/1)
    :ok
  end

  defp require_row_inputs!(row) do
    case row do
      %__MODULE__{} = example ->
        input_keys!(example, "inputs")

      row when (is_map(row) and not is_struct(row)) or is_list(row) ->
        raise ArgumentError,
              "a plain map or field pair list cannot declare which fields are inputs; build " <>
                "the row with Imp.example/1 and call Imp.with_inputs/2 on it. Got: " <>
                inspect(row)

      _row ->
        :ok
    end
  end

  defp input_keys!(%__MODULE__{input_keys: nil} = example, function) do
    raise ArgumentError,
          "Imp.Example.#{function}/1 needs the example's inputs declared; call " <>
            "Imp.with_inputs/2 (Imp.Example.with_inputs/2) first. Example keys: " <>
            inspect(keys(example))
  end

  defp input_keys!(%__MODULE__{input_keys: keys}, _function), do: keys

  @doc "Attaches demonstrations to an example."
  def with_demos(%__MODULE__{} = example, demos),
    do: %{example | demos: normalize_demos!(demos, "Imp.Example.with_demos/2")}

  @doc false
  def normalize_demos!(demos, context) do
    cond do
      match?(%__MODULE__{}, demos) or is_map(demos) or field_pair_list?(demos) ->
        [normalize_demo!(demos, context)]

      is_list(demos) ->
        Enum.map(demos, &normalize_demo!(&1, context))

      true ->
        raise ArgumentError,
              "#{context} expects a demo, field pair list, or list of demos; got: #{inspect(demos)}"
    end
  end

  defp normalize_demo!(%__MODULE__{} = example, _context), do: example
  defp normalize_demo!(demo, _context) when is_map(demo) or is_list(demo), do: new(demo)

  defp normalize_demo!(demo, context) do
    raise ArgumentError,
          "#{context} expects demos as Imp.Example structs, maps, or field pair lists; got: #{inspect(demo)}"
  end

  defp key!(key), do: Imp.FieldMap.key!(key, "Imp.Example")

  defp internal?(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.starts_with?("imp_")

  defp internal?(key) when is_binary(key), do: String.starts_with?(key, "imp_")

  defp field_pair_list?(value) when is_list(value) do
    value != [] and
      Enum.all?(value, fn
        {key, _value} when is_atom(key) or is_binary(key) -> true
        _other -> false
      end)
  end

  defp field_pair_list?(_value), do: false
end
