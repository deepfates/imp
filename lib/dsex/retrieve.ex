defmodule DSEx.Retrieve do
  @moduledoc "Retriever behaviour and simple in-memory implementation."

  @callback retrieve(query :: String.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  def retrieve(retriever, query, opts \\ [])

  def retrieve(module, query, opts) when is_atom(module) do
    if function_exported?(module, :retrieve, 2) do
      call_retriever(fn -> module.retrieve(query, opts) end, module)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  def retrieve(fun, query, opts) when is_function(fun, 2) do
    call_retriever(fn -> fun.(query, opts) end, fun)
  end

  def retrieve(%module{} = retriever, query, opts) do
    if function_exported?(module, :retrieve, 3) do
      call_retriever(fn -> module.retrieve(retriever, query, opts) end, module)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  def retrieve(retriever, _query, _opts), do: {:error, {:not_a_retriever, retriever}}

  defp call_retriever(fun, retriever) do
    case fun.() do
      {:ok, docs} when is_list(docs) -> {:ok, docs}
      {:error, _reason} = error -> error
      {:ok, other} -> {:error, {:invalid_retriever_result, other}}
      other -> {:error, {:invalid_retriever_result, other}}
    end
  rescue
    error -> {:error, {:retriever_failed, retriever_name(retriever), error_message(error)}}
  catch
    kind, reason ->
      {:error, {:retriever_failed, retriever_name(retriever), error_message({kind, reason})}}
  end

  defp retriever_name(retriever) when is_atom(retriever), do: retriever
  defp retriever_name(fun) when is_function(fun), do: :anonymous_retriever
  defp retriever_name(%module{}), do: module
  defp retriever_name(other), do: other

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)

  defmodule Memory do
    @moduledoc "Token-overlap in-memory retriever for deterministic local workflows."
    @behaviour DSEx.Retrieve

    defstruct docs: [], k: 3

    def new(docs, opts \\ []),
      do: %__MODULE__{docs: docs, k: non_negative_integer(Keyword.get(opts, :k, 3))}

    @impl true
    def retrieve(%__MODULE__{} = retriever, query, opts \\ []) do
      k = non_negative_integer(Keyword.get(opts, :k, retriever.k))
      query_terms = terms(query)

      docs =
        retriever.docs
        |> Enum.map(fn doc -> {score(doc, query_terms), doc} end)
        |> Enum.sort_by(fn {score, _doc} -> -score end)
        |> Enum.take(k)
        |> Enum.map(fn {score, doc} -> Map.put(Map.new(doc), :score, score) end)

      {:ok, docs}
    end

    defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
    defp non_negative_integer(_value), do: 0

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
