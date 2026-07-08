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

  def new(program, retriever, opts \\ []) do
    %__MODULE__{
      program: program,
      retriever: retriever,
      query_field: Keyword.get(opts, :query_field, :question),
      context_field: Keyword.get(opts, :context_field, :context),
      k: Keyword.get(opts, :k, 3)
    }
  end

  @impl true
  def call(%__MODULE__{} = rag, inputs) do
    inputs = Map.new(inputs)
    query = query_text(inputs, rag.query_field)

    with {:ok, docs} <- DSEx.Retrieve.retrieve(rag.retriever, query, k: rag.k),
         enriched <- Map.put(inputs, rag.context_field, render_context(docs)) do
      case DSEx.Module.call(rag.program, enriched) do
        {:ok, %DSEx.Prediction{} = prediction} ->
          {:ok, attach_retrieval(prediction, query, docs)}

        {:ok, other} ->
          {:error, {:invalid_rag_prediction, inspect(other)}}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_rag_result, inspect(other)}}
      end
    end
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
    |> Enum.map_join("\n\n", fn doc ->
      doc
      |> Map.new()
      |> Map.get(:text, Map.get(Map.new(doc), "text", inspect(doc)))
      |> to_string()
    end)
  end

  defp attach_retrieval(%DSEx.Prediction{metadata: metadata} = prediction, query, docs) do
    retrieval = %{
      query: query,
      count: length(docs),
      docs: Enum.map(docs, &Map.new/1)
    }

    %{prediction | metadata: Map.put(metadata, :retrieval, DSEx.Redaction.redact(retrieval))}
  end
end
