defmodule DSEx.Predict.RAG do
  @moduledoc """
  Retrieval-augmented program wrapper.

  `RAG` composes an ordinary DSEx program with a retriever. On each call it
  retrieves documents for the input query, writes a rendered context field into
  the program inputs, calls the wrapped program, and attaches retrieval metadata
  to the returned prediction.
  """

  @behaviour DSEx.Module

  defstruct [:program, :retriever, query_field: :question, context_field: :context, k: 3]

  @option_schema [
    query_field: [type: :any, default: :question],
    context_field: [type: :any, default: :context],
    k: [type: :any, default: 3]
  ]

  def new(program, retriever, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.RAG.new/3")

    %__MODULE__{
      program: program,
      retriever: retriever,
      query_field: opts[:query_field],
      context_field: opts[:context_field],
      k: non_negative_integer(opts[:k])
    }
  end

  @impl true
  def call(%__MODULE__{} = rag, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         query <- query_text(inputs, rag.query_field),
         {:ok, docs} <- DSEx.Retrieve.retrieve(rag.retriever, query, k: rag.k),
         {:ok, context} <- render_context(docs),
         enriched <- Map.put(inputs, rag.context_field, context) do
      call_wrapped_program(rag, enriched, query, docs)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_rag_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  defp call_wrapped_program(rag, enriched, query, docs) do
    case DSEx.Module.call(rag.program, enriched) do
      {:ok, %DSEx.Prediction{} = prediction} ->
        attach_retrieval(prediction, query, docs)

      {:ok, other} ->
        {:error, {:invalid_rag_prediction, inspect(other)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_rag_result, inspect(other)}}
    end
  end

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_rag_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp query_text(inputs, fields) when is_list(fields) do
    fields
    |> Enum.map(&Map.get(inputs, &1, Map.get(inputs, to_string(&1), "")))
    |> Enum.join(" ")
  end

  defp query_text(inputs, field),
    do: Map.get(inputs, field, Map.get(inputs, to_string(field), ""))

  defp render_context(docs) do
    docs
    |> Enum.reduce_while({:ok, []}, fn doc, {:ok, rendered} ->
      case normalize_doc(doc) do
        {:ok, normalized} ->
          text = Map.get(normalized, :text, Map.get(normalized, "text", inspect(doc)))
          {:cont, {:ok, [to_string(text) | rendered]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, rendered |> Enum.reverse() |> Enum.join("\n\n")}
      error -> error
    end
  end

  defp attach_retrieval(%DSEx.Prediction{metadata: metadata} = prediction, query, docs) do
    with {:ok, docs} <- normalize_docs(docs) do
      retrieval = %{
        query: query,
        count: length(docs),
        docs: docs
      }

      {:ok,
       %{prediction | metadata: Map.put(metadata, :retrieval, DSEx.Redaction.redact(retrieval))}}
    end
  end

  defp normalize_docs(docs) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, normalized_docs} ->
      case normalize_doc(doc) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | normalized_docs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  defp normalize_doc(doc) when is_list(doc) or is_map(doc) do
    {:ok, Map.new(doc)}
  rescue
    _error -> {:error, {:invalid_rag_document, doc}}
  end

  defp normalize_doc(doc), do: {:error, {:invalid_rag_document, doc}}

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end
