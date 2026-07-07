defmodule DSEx.Retrievers.KNN do
  @moduledoc "K-nearest-neighbor helper over examples using token overlap."

  defstruct examples: [], k: 3, field: :question

  def new(examples, opts \\ []) do
    %__MODULE__{
      examples: examples,
      k: non_negative_integer(Keyword.get(opts, :k, 3)),
      field: Keyword.get(opts, :field, :question)
    }
  end

  def call(%__MODULE__{} = knn, query) do
    query_terms = terms(query)

    knn.examples
    |> Enum.map(fn example ->
      {score(DSEx.Example.get(example, knn.field), query_terms), example}
    end)
    |> Enum.sort_by(fn {score, _example} -> -score end)
    |> Enum.take(knn.k)
    |> Enum.map(fn {_score, example} -> example end)
  end

  defp score(text, query_terms),
    do: MapSet.intersection(MapSet.new(terms(text)), MapSet.new(query_terms)) |> MapSet.size()

  defp terms(text),
    do:
      Regex.scan(~r/[a-z0-9]+/i, to_string(text))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end
