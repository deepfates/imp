defmodule DSPy.Prediction do
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
    do: Map.get(fields, normalize_key(key), default)

  def fetch!(%__MODULE__{fields: fields}, key), do: Map.fetch!(fields, normalize_key(key))

  def put(%__MODULE__{fields: fields} = prediction, key, value),
    do: %{prediction | fields: Map.put(fields, normalize_key(key), value)}

  def to_map(%__MODULE__{fields: fields}), do: fields

  def from_example(%DSPy.Example{} = example, opts \\ []),
    do: new(DSPy.Example.to_map(example), opts)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
end
