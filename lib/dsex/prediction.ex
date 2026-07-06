defmodule DSEx.Prediction do
  @moduledoc "A model output, represented as fields plus completions metadata."

  @type t :: %__MODULE__{
          fields: map(),
          completions: list(),
          score: number() | nil,
          metadata: map()
        }
  defstruct fields: %{}, completions: [], score: nil, metadata: %{}

  def new(fields \\ %{}, opts \\ []) do
    %__MODULE__{
      fields: fields |> Map.new(fn {k, v} -> {normalize_key(k), v} end),
      completions: Keyword.get(opts, :completions, []),
      score: Keyword.get(opts, :score),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def get(%__MODULE__{fields: fields}, key, default \\ nil),
    do: get_key(fields, normalize_key(key), default)

  def fetch!(%__MODULE__{fields: fields}, key) do
    case fetch_key(fields, normalize_key(key)) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: fields
    end
  end

  def put(%__MODULE__{fields: fields} = prediction, key, value),
    do: %{prediction | fields: Map.put(fields, normalize_key(key), value)}

  def to_map(%__MODULE__{fields: fields}), do: fields

  def from_example(%DSEx.Example{} = example, opts \\ []),
    do: new(DSEx.Example.to_map(example), opts)

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
end
