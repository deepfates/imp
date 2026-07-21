defmodule Imp.Predict.RAG do
  @moduledoc """
  Retrieval-augmented program wrapper.

  `RAG` composes an ordinary Imp program with a retriever. On each call it
  retrieves documents for the input query, writes a rendered context field into
  the program inputs, calls the wrapped program, and attaches retrieval metadata
  to the returned prediction. Set `hops: 2` or higher for iterative multi-hop
  retrieval: each hop expands the original query with previously retrieved
  passages before retrieving again.

  Use RAG when retrieval is part of the program, not when a caller has already
  prepared all context. The wrapped program remains an ordinary Imp executable
  module, so it can still be evaluated, optimized, streamed, and saved when the
  retriever is portable.
  """

  @behaviour Imp.Module

  defstruct [:program, :retriever, query_field: :question, context_field: :context, k: 3, hops: 1]

  @option_schema [
    query_field: [
      type: {:custom, Imp.FieldSelector, :validate_selector, []},
      default: :question
    ],
    context_field: [
      type: {:custom, Imp.FieldSelector, :validate_name, []},
      default: :context
    ],
    k: [type: :non_neg_integer, default: 3],
    hops: [type: :pos_integer, default: 1]
  ]

  def new(program, retriever, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.RAG.new/3")

    %__MODULE__{
      program: program,
      retriever: retriever,
      query_field: opts[:query_field],
      context_field: opts[:context_field],
      k: opts[:k],
      hops: opts[:hops]
    }
  end

  @doc """
  Runs retrieval, injects context, calls the wrapped program, and records metadata.

      iex> lm = %{
      ...>   module: Imp.LM.Static,
      ...>   opts: [handler: fn messages, _opts ->
      ...>     prompt = Enum.map_join(messages, " ", & &1.content)
      ...>     if prompt =~ "France has capital Paris", do: %{answer: "Paris"}, else: %{answer: "unknown"}
      ...>   end]
      ...> }
      iex> base = Imp.Predict.Predict.new("question, context -> answer", lm: lm)
      iex> retriever = Imp.Retrieve.Memory.new([%{text: "France has capital Paris"}], k: 1)
      iex> rag = Imp.Predict.RAG.new(base, retriever, k: 1)
      iex> {:ok, prediction} = Imp.Predict.RAG.call(rag, %{question: "capital France"})
      iex> {Imp.Prediction.get(prediction, :answer), prediction.metadata.retrieval.count}
      {"Paris", 1}

  """
  @impl true
  def call(%__MODULE__{} = rag, inputs) when is_list(inputs) or is_map(inputs) do
    with {:ok, inputs} <- normalize_inputs(inputs),
         query <- query_text(inputs, rag.query_field),
         {:ok, retrieval} <- retrieve_hops(rag, query),
         {:ok, context} <- render_context(retrieval.docs),
         enriched <- Map.put(inputs, rag.context_field, context) do
      call_wrapped_program(rag, drop_consumed_query_fields(rag, enriched), query, retrieval)
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_rag_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  defp retrieve_hops(%__MODULE__{} = rag, original_query) do
    1..rag.hops
    |> Enum.reduce_while({:ok, %{docs: [], hops: [], query: to_string(original_query)}}, fn hop,
                                                                                            {:ok,
                                                                                             acc} ->
      with {:ok, raw_docs} <- Imp.Retrieve.retrieve(rag.retriever, acc.query, k: rag.k),
           {:ok, docs} <- normalize_docs(raw_docs) do
        all_docs = dedupe_docs(acc.docs ++ docs)
        hop_record = %{hop: hop, query: acc.query, count: length(docs), docs: docs}

        {:cont,
         {:ok,
          %{
            docs: all_docs,
            hops: acc.hops ++ [hop_record],
            query: expand_query(original_query, all_docs)
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, retrieval} -> {:ok, Map.delete(retrieval, :query)}
      error -> error
    end
  end

  defp expand_query(original_query, docs) do
    [to_string(original_query) | Enum.map(docs, &doc_text/1)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp dedupe_docs(docs), do: Enum.uniq_by(docs, &doc_key/1)

  defp doc_key(doc) do
    Map.get(doc, :id) || Map.get(doc, "id") || Map.get(doc, :text) || Map.get(doc, "text") ||
      inspect(doc)
  end

  defp doc_text(doc), do: doc |> Map.get(:text, Map.get(doc, "text", "")) |> to_string()

  defp call_wrapped_program(rag, enriched, query, retrieval) do
    case Imp.Module.call(rag.program, enriched) do
      {:ok, %Imp.Prediction{} = prediction} ->
        attach_retrieval(prediction, query, retrieval)

      {:ok, other} ->
        {:error, {:invalid_rag_prediction, inspect(other)}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_rag_result, inspect(other)}}
    end
  end

  # Query fields RAG has already consumed for retrieval are RAG's own input,
  # not the wrapped program's; when the wrapped program's signature does not
  # declare them, they are dropped here ON PURPOSE so Predict's extra-input
  # warning (de-hzcv gap #2) does not fire on RAG-consumed keys. When the
  # wrapped program has no readable signature nothing is dropped and the
  # program's own validation applies.
  defp drop_consumed_query_fields(rag, enriched) do
    case declared_input_names(rag.program) do
      nil ->
        enriched

      declared ->
        rag.query_field
        |> List.wrap()
        |> Enum.reject(&MapSet.member?(declared, to_string(&1)))
        |> Enum.flat_map(&[&1, to_string(&1)])
        |> then(&Map.drop(enriched, &1))
    end
  end

  defp declared_input_names(%{signature: %Imp.Signature{inputs: inputs}}),
    do: MapSet.new(inputs, &to_string(&1.name))

  defp declared_input_names(_program), do: nil

  defp normalize_inputs(inputs) do
    {:ok, Map.new(inputs)}
  rescue
    _error -> {:error, {:invalid_rag_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp query_text(inputs, fields) when is_list(fields) do
    fields
    |> Enum.map(&field_value(inputs, &1, ""))
    |> Enum.join(" ")
  end

  defp query_text(inputs, field),
    do: field_value(inputs, field, "")

  defp field_value(inputs, field, default) do
    cond do
      Map.has_key?(inputs, field) ->
        Map.fetch!(inputs, field)

      Map.has_key?(inputs, to_string(field)) ->
        Map.fetch!(inputs, to_string(field))

      is_binary(field) ->
        existing_atom_value(inputs, field, default)

      true ->
        default
    end
  end

  defp existing_atom_value(inputs, field, default) do
    atom = String.to_existing_atom(field)
    Map.get(inputs, atom, default)
  rescue
    ArgumentError -> default
  end

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

  defp attach_retrieval(%Imp.Prediction{metadata: metadata} = prediction, query, retrieval) do
    docs = retrieval.docs

    metadata_retrieval = %{
      query: query,
      count: length(docs),
      docs: docs,
      hops: Map.get(retrieval, :hops, [])
    }

    {:ok,
     %{
       prediction
       | metadata: Map.put(metadata, :retrieval, Imp.Redaction.redact(metadata_retrieval))
     }}
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
end
