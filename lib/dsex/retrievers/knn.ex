defmodule DSEx.Retrievers.KNN do
  @moduledoc "K-nearest-neighbor helper over examples using token overlap."

  defstruct examples: [], k: 3, field: :question

  @option_schema [
    k: [type: :any, default: 3],
    field: [type: :any, default: :question]
  ]

  def new(examples, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Retrievers.KNN.new/2")

    %__MODULE__{
      examples: examples,
      k: non_negative_integer(opts[:k]),
      field: opts[:field]
    }
  end

  def call(%__MODULE__{} = knn, query) do
    query_terms = terms(query)

    knn.examples
    |> Enum.map(fn example ->
      {score(example_text(example, knn.field), query_terms), example}
    end)
    |> Enum.sort_by(fn {score, _example} -> -score end)
    |> Enum.take(knn.k)
    |> Enum.map(fn {_score, example} -> example end)
  end

  defp example_text(example, fields) when is_list(fields) do
    fields
    |> Enum.map(&DSEx.Example.get(example, &1, ""))
    |> Enum.map_join(" ", &safe_text/1)
  end

  defp example_text(example, field), do: example |> DSEx.Example.get(field, "") |> safe_text()

  defp score(text, query_terms),
    do: MapSet.intersection(MapSet.new(terms(text)), MapSet.new(query_terms)) |> MapSet.size()

  defp terms(text),
    do:
      Regex.scan(~r/[a-z0-9]+/i, to_string(text))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp safe_text(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end
