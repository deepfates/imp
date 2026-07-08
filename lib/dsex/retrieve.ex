defmodule DSEx.Retrieve do
  @moduledoc "Retriever behaviour and simple in-memory implementation."

  @callback retrieve(query :: String.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  def retrieve(retriever, query, opts \\ [])

  def retrieve(retriever, query, opts) do
    opts = validate_opts!(opts)
    do_retrieve(retriever, query, opts)
  end

  defp do_retrieve(module, query, opts) when is_atom(module) do
    if function_exported?(module, :retrieve, 2) do
      call_retriever(fn -> module.retrieve(query, opts) end, module)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  defp do_retrieve(fun, query, opts) when is_function(fun, 2) do
    call_retriever(fn -> fun.(query, opts) end, fun)
  end

  defp do_retrieve(%module{} = retriever, query, opts) do
    if function_exported?(module, :retrieve, 3) do
      call_retriever(fn -> module.retrieve(retriever, query, opts) end, module)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  defp do_retrieve(retriever, _query, _opts), do: {:error, {:not_a_retriever, retriever}}

  defp validate_opts!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError,
            "DSEx.Retrieve.retrieve/3 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts) do
    raise ArgumentError, "DSEx.Retrieve.retrieve/3 expects keyword options, got: #{inspect(opts)}"
  end

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

    @option_schema [
      k: [type: :any, default: 3]
    ]

    @retrieve_option_schema [
      k: [type: :any]
    ]

    def new(docs, opts \\ [])

    def new(docs, opts) when is_list(docs) do
      opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Retrieve.Memory.new/2")
      %__MODULE__{docs: docs, k: non_negative_integer(opts[:k])}
    end

    def new(docs, _opts) do
      raise ArgumentError,
            "DSEx.Retrieve.Memory.new/2 expects a list of document maps or field pair lists; got: #{inspect(docs)}"
    end

    @impl true
    def retrieve(%__MODULE__{} = retriever, query, opts \\ []) do
      opts =
        DSEx.Options.validate!(opts, @retrieve_option_schema, "DSEx.Retrieve.Memory.retrieve/3")

      k = non_negative_integer(opts[:k] || retriever.k)
      query_terms = terms(query)

      with {:ok, docs} <- normalize_docs(retriever.docs) do
        docs =
          docs
          |> Enum.map(fn doc -> {score(doc, query_terms), doc} end)
          |> Enum.sort_by(fn {score, _doc} -> -score end)
          |> Enum.take(k)
          |> Enum.map(fn {score, doc} -> Map.put(doc, :score, score) end)

        {:ok, docs}
      end
    end

    defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
    defp non_negative_integer(_value), do: 0

    defp normalize_docs(docs) do
      Enum.reduce_while(docs, {:ok, []}, fn
        doc, {:ok, normalized_docs} when is_list(doc) or is_map(doc) ->
          try do
            {:cont, {:ok, [Map.new(doc) | normalized_docs]}}
          rescue
            _error ->
              {:halt, {:error, {:invalid_memory_document, doc}}}
          end

        doc, _acc ->
          {:halt, {:error, {:invalid_memory_document, doc}}}
      end)
      |> case do
        {:ok, docs} -> {:ok, Enum.reverse(docs)}
        error -> error
      end
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
