defmodule DSEx.BenchmarkTruth.HoverBM25 do
  @moduledoc false

  @behaviour DSEx.Module

  @k1 0.9
  @b 0.4

  defstruct [:corpus_path, :docs, :avgdl, :doc_count, :idf, :metadata, k: 24]

  def new(%{"corpus_path" => corpus_path} = retrieval, opts \\ []) do
    k = Keyword.get(opts, :k, 24)
    corpus_path = Path.expand(corpus_path)

    unless File.exists?(corpus_path) do
      raise ArgumentError, "HoVer BM25 corpus not found: #{corpus_path}"
    end

    docs = load_corpus!(corpus_path)
    {avgdl, doc_count, idf} = corpus_stats(docs)

    %__MODULE__{
      corpus_path: corpus_path,
      docs: docs,
      avgdl: avgdl,
      doc_count: doc_count,
      idf: idf,
      k: k
    }
    |> Map.put(
      :metadata,
      Map.take(retrieval, ["kind", "source_url", "corpus_checksum", "index_checksum"])
    )
  end

  @impl true
  def call(%__MODULE__{} = retriever, inputs) do
    claim =
      inputs
      |> Map.new()
      |> Map.get(:claim, Map.get(Map.new(inputs), "claim", ""))

    docs =
      retriever
      |> retrieve(claim)
      |> Enum.map(fn doc -> "#{doc.title} | #{doc.text}" end)

    {:ok, DSEx.Prediction.new(retrieved_docs: docs)}
  end

  def retrieve(%__MODULE__{} = retriever, query) do
    query_terms = terms(query)

    retriever.docs
    |> Enum.map(fn doc -> {bm25(doc, query_terms, retriever), doc} end)
    |> Enum.sort_by(fn {score, _doc} -> -score end)
    |> Enum.take(retriever.k)
    |> Enum.map(fn {_score, doc} -> doc end)
  end

  defp load_corpus!(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      title = to_string(row["title"] || row[:title] || "")
      text = corpus_text(row["text"] || row[:text] || "")
      tokens = terms(title <> " " <> text)
      %{title: title, text: text, tokens: tokens, length: length(tokens)}
    end)
  end

  defp corpus_text(value) when is_list(value), do: Enum.map_join(value, " ", &to_string/1)
  defp corpus_text(value), do: to_string(value)

  defp corpus_stats(docs) do
    doc_count = length(docs)
    avgdl = Enum.sum(Enum.map(docs, & &1.length)) / max(doc_count, 1)

    document_frequency =
      Enum.reduce(docs, %{}, fn doc, acc ->
        doc.tokens
        |> MapSet.new()
        |> Enum.reduce(acc, fn term, acc -> Map.update(acc, term, 1, &(&1 + 1)) end)
      end)

    idf =
      Map.new(document_frequency, fn {term, df} ->
        {term, :math.log((doc_count - df + 0.5) / (df + 0.5) + 1.0)}
      end)

    {avgdl, doc_count, idf}
  end

  defp bm25(doc, query_terms, retriever) do
    frequencies = Enum.frequencies(doc.tokens)

    query_terms
    |> MapSet.new()
    |> Enum.reduce(0.0, fn term, acc ->
      freq = Map.get(frequencies, term, 0)
      idf = Map.get(retriever.idf, term, 0.0)
      denominator = freq + @k1 * (1 - @b + @b * doc.length / max(retriever.avgdl, 1.0))

      if freq > 0 and denominator > 0 do
        acc + idf * (freq * (@k1 + 1)) / denominator
      else
        acc
      end
    end)
  end

  defp terms(text) do
    Regex.scan(~r/[a-z0-9]+/i, to_string(text))
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&MapSet.member?(stopwords(), &1))
  end

  defp stopwords do
    MapSet.new(~w[
      a an and are as at be but by for from has have in is it its of on or
      that the this to was were will with
    ])
  end
end
