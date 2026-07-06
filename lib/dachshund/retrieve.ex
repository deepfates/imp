defmodule Dachshund.Retrieve do
  @moduledoc "Retriever behaviour and simple in-memory implementation."

  @callback retrieve(query :: String.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  def retrieve(retriever, query, opts \\ [])
  def retrieve(module, query, opts) when is_atom(module), do: module.retrieve(query, opts)
  def retrieve(fun, query, opts) when is_function(fun, 2), do: fun.(query, opts)

  def retrieve(%module{} = retriever, query, opts) do
    if function_exported?(module, :retrieve, 3) do
      module.retrieve(retriever, query, opts)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  defmodule Memory do
    @moduledoc "Token-overlap in-memory retriever for deterministic local workflows."
    @behaviour Dachshund.Retrieve

    defstruct docs: [], k: 3

    def new(docs, opts \\ []), do: %__MODULE__{docs: docs, k: Keyword.get(opts, :k, 3)}

    @impl true
    def retrieve(%__MODULE__{} = retriever, query, opts \\ []) do
      k = Keyword.get(opts, :k, retriever.k)
      query_terms = terms(query)

      docs =
        retriever.docs
        |> Enum.map(fn doc -> {score(doc, query_terms), doc} end)
        |> Enum.sort_by(fn {score, _doc} -> -score end)
        |> Enum.take(k)
        |> Enum.map(fn {score, doc} -> Map.put(Map.new(doc), :score, score) end)

      {:ok, docs}
    end

    defp score(doc, query_terms) do
      text = Map.get(doc, :text, Map.get(doc, "text", ""))
      MapSet.intersection(MapSet.new(terms(text)), MapSet.new(query_terms)) |> MapSet.size()
    end

    defp terms(text),
      do:
        Regex.scan(~r/[a-z0-9]+/i, to_string(text))
        |> List.flatten()
        |> Enum.map(&String.downcase/1)
  end
end
