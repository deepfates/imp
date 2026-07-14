defmodule Imp.Retrievers.KNN do
  @moduledoc "K-nearest-neighbor helper over examples using token overlap."

  defstruct examples: [], k: 3, field: :question

  @option_schema [
    k: [type: :non_neg_integer, default: 3],
    field: [
      type: {:custom, Imp.FieldSelector, :validate_selector, []},
      default: :question
    ]
  ]

  def new(examples, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Retrievers.KNN.new/2")

    %__MODULE__{
      examples: validate_examples!(examples),
      k: opts[:k],
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
    |> Enum.map(&Imp.Example.get(example, &1, ""))
    |> Enum.map_join(" ", &safe_text/1)
  end

  defp example_text(example, field), do: example |> Imp.Example.get(field, "") |> safe_text()

  defp score(text, query_terms),
    do: MapSet.intersection(MapSet.new(terms(text)), MapSet.new(query_terms)) |> MapSet.size()

  defp terms(text),
    do:
      Regex.scan(~r/[a-z0-9]+/i, to_string(text))
      |> List.flatten()
      |> Enum.map(&String.downcase/1)

  defp validate_examples!(examples) do
    if Enumerable.impl_for(examples) do
      Enum.to_list(examples)
    else
      raise ArgumentError,
            "Imp.Retrievers.KNN.new/2 expects examples to be an enumerable; got: #{inspect(examples)}"
    end
  end

  defp safe_text(value) do
    case String.Chars.impl_for(value) do
      nil -> inspect(value)
      _impl -> to_string(value)
    end
  end
end
