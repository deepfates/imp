defmodule Imp.Retrieve do
  @moduledoc """
  Retriever behaviour and dispatch boundary for RAG-style Imp programs.

  A retriever is a struct whose module implements this behaviour, such a
  module itself, or a two-argument function `(query, opts)`. All retrievers
  return `{:ok, docs}` or `{:error, reason}`. Documents are normalized to maps,
  so keyword-list documents are accepted while malformed rows fail before they
  reach a RAG program.
  """

  @typedoc "A retriever: a struct or module implementing this behaviour, or a function."
  @type t :: struct() | module() | (String.t(), keyword() -> {:ok, list()} | {:error, term()})

  @doc """
  Returns the documents for `query`. `retriever` is the struct or the module
  as it was given.
  """
  @callback retrieve(retriever :: struct() | module(), query :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, term()}

  def retrieve(retriever, query, opts \\ [])

  @doc """
  Calls a retriever and normalizes returned documents.

      iex> retriever = fn query, opts ->
      ...>   {:ok, [[text: "query=" <> query, k: opts[:k]]]}
      ...> end
      iex> Imp.Retrieve.retrieve(retriever, "beam", k: 1)
      {:ok, [%{text: "query=beam", k: 1}]}

      iex> Imp.Retrieve.retrieve(fn _query, _opts -> {:ok, [:bad_doc]} end, "beam")
      {:error, {:invalid_retriever_document, :bad_doc}}

  """
  def retrieve(retriever, query, opts) do
    opts = validate_opts!(opts)
    do_retrieve(retriever, query, opts)
  end

  defp do_retrieve(module, query, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :retrieve, 3) do
      call_retriever(fn -> module.retrieve(module, query, opts) end, module)
    else
      {:error, {:not_a_retriever, module}}
    end
  end

  defp do_retrieve(fun, query, opts) when is_function(fun, 2) do
    call_retriever(fn -> fun.(query, opts) end, fun)
  end

  defp do_retrieve(%module{} = retriever, query, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :retrieve, 3) do
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
            "Imp.Retrieve.retrieve/3 expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts) do
    raise ArgumentError, "Imp.Retrieve.retrieve/3 expects keyword options, got: #{inspect(opts)}"
  end

  defp call_retriever(fun, retriever) do
    case fun.() do
      {:ok, docs} when is_list(docs) -> normalize_docs(docs)
      {:error, _reason} = error -> error
      {:ok, other} -> {:error, {:invalid_retriever_result, other}}
      other -> {:error, {:invalid_retriever_result, other}}
    end
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, {:retriever_failed, retriever_name(retriever), error}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          {:error, safety}

        nil ->
          {:error, {:retriever_failed, retriever_name(retriever), {kind, reason}}}
      end
  end

  defp normalize_docs(docs) do
    Enum.reduce_while(docs, {:ok, []}, fn
      doc, {:ok, normalized_docs} when is_map(doc) ->
        {:cont, {:ok, [doc | normalized_docs]}}

      doc, {:ok, normalized_docs} when is_list(doc) ->
        if Keyword.keyword?(doc) do
          {:cont, {:ok, [Map.new(doc) | normalized_docs]}}
        else
          {:halt, {:error, {:invalid_retriever_document, doc}}}
        end

      doc, _acc ->
        {:halt, {:error, {:invalid_retriever_document, doc}}}
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  defp retriever_name(retriever) when is_atom(retriever), do: retriever
  defp retriever_name(fun) when is_function(fun), do: :anonymous_retriever
  defp retriever_name(%module{}), do: module
  defp retriever_name(other), do: other

  defmodule Memory do
    @moduledoc """
    Token-overlap in-memory retriever for deterministic local workflows.

    `Memory` is useful for examples, tests, Livebooks, and portable save/load
    workflows. It scores documents by token overlap with the query and returns
    up to `k` of the documents that share at least one token with it, best
    first, each with an added `:score` field. A document that shares none is
    not a match and is not returned.
    """
    @behaviour Imp.Retrieve

    defstruct docs: [], k: 3

    @option_schema [
      k: [type: :non_neg_integer, default: 3]
    ]

    @retrieve_option_schema [
      k: [type: :non_neg_integer]
    ]

    def new(docs, opts \\ [])

    @doc """
    Builds an in-memory retriever from document maps or keyword-list documents.

        iex> retriever = Imp.Retrieve.Memory.new([[text: "Elixir runs on the BEAM"]], k: 1)
        iex> {:ok, docs} = Imp.Retrieve.retrieve(retriever, "BEAM")
        iex> docs
        [%{text: "Elixir runs on the BEAM", score: 1}]

    """
    def new(docs, opts) when is_list(docs) do
      opts = Imp.Options.validate!(opts, @option_schema, "Imp.Retrieve.Memory.new/2")
      %__MODULE__{docs: docs, k: opts[:k]}
    end

    def new(docs, _opts) do
      raise ArgumentError,
            "Imp.Retrieve.Memory.new/2 expects a list of document maps or field pair lists; got: #{inspect(docs)}"
    end

    @impl true
    def retrieve(retriever, query, opts \\ [])

    def retrieve(%__MODULE__{} = retriever, query, opts) do
      opts =
        Imp.Options.validate!(opts, @retrieve_option_schema, "Imp.Retrieve.Memory.retrieve/3")

      k = opts[:k] || retriever.k
      query_terms = terms(query)

      with {:ok, docs} <- normalize_docs(retriever.docs) do
        docs =
          docs
          |> Enum.map(fn doc -> {score(doc, query_terms), doc} end)
          |> Enum.reject(fn {score, _doc} -> score == 0 end)
          |> Enum.sort_by(fn {score, _doc} -> -score end)
          |> Enum.take(k)
          |> Enum.map(fn {score, doc} -> Map.put(doc, :score, score) end)

        {:ok, docs}
      end
    end

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
