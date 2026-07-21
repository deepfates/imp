defmodule Imp.BenchmarkTruth.HoverBM25 do
  @moduledoc false

  @behaviour Imp.Module

  @k1 0.9
  @b 0.4
  @native_implementation "imp_native_bm25_approximation"

  defstruct [:corpus_path, :docs, :avgdl, :doc_count, :idf, :metadata, k: 24]

  def new(%{"corpus_path" => corpus_path} = retrieval, opts \\ []) do
    verify_source!(retrieval)
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
      retrieval
      |> Map.take(["kind", "source_url", "corpus_checksum", "index_checksum"])
      |> Map.merge(%{
        "implementation" => @native_implementation,
        "ranking_parity" => "approximate",
        "deviation" => "no bm25s English stopword tokenizer or PyStemmer stemming"
      })
    )
  end

  @doc false
  def verify_source!(retrieval) when is_map(retrieval) do
    verify_checksum!(retrieval, "corpus_path", "corpus_checksum")
    verify_checksum!(retrieval, "index_path", "index_checksum")
    :ok
  end

  @doc false
  def checksum_path(path) do
    path = Path.expand(path)

    cond do
      File.regular?(path) -> file_checksum(path)
      File.dir?(path) -> tree_checksum(path)
      true -> raise ArgumentError, "HoVer retrieval source not found: #{path}"
    end
  end

  defp verify_checksum!(retrieval, path_key, checksum_key) do
    path = retrieval[path_key] || raise ArgumentError, "HoVer retrieval missing #{path_key}"

    expected =
      case retrieval[checksum_key] do
        "sha256:" <> digest when byte_size(digest) == 64 -> String.downcase(digest)
        _ -> raise ArgumentError, "HoVer retrieval missing valid #{checksum_key}"
      end

    actual = checksum_path(path)

    unless actual == expected do
      raise ArgumentError,
            "HoVer retrieval #{checksum_key} mismatch for #{Path.expand(path)}: expected #{expected}, got #{actual}"
    end
  end

  defp file_checksum(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp tree_checksum(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, context ->
      relative = path |> Path.relative_to(root) |> String.replace("\\", "/")
      context = :crypto.hash_update(context, relative <> <<0>>)

      context =
        path
        |> File.stream!(1_048_576)
        |> Enum.reduce(context, &:crypto.hash_update(&2, &1))

      :crypto.hash_update(context, <<0>>)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
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

    {:ok, Imp.Prediction.new(retrieved_docs: docs)}
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

defmodule Imp.BenchmarkTruth.HoverBM25.UpstreamPython do
  @moduledoc false

  @behaviour Imp.Module

  @upstream_commit "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
  @bm25s_version "0.2.12"

  defstruct [:gepa_root, :python, :metadata, k: 24]

  def new(retrieval, opts \\ []) do
    Imp.BenchmarkTruth.HoverBM25.verify_source!(retrieval)
    corpus_path = Map.fetch!(retrieval, "corpus_path")
    index_path = Map.fetch!(retrieval, "index_path")

    gepa_root =
      Keyword.get(opts, :gepa_root) || System.get_env("IMP_GEPA_ROOT") ||
        infer_gepa_root!(corpus_path)

    python = Keyword.get(opts, :python) || System.get_env("IMP_GEPA_PYTHON") || "python3"

    unless File.exists?(Path.expand(corpus_path)) do
      raise ArgumentError, "HoVer BM25 corpus not found: #{corpus_path}"
    end

    unless File.exists?(Path.expand(index_path)) do
      raise ArgumentError, "HoVer BM25 index not found: #{index_path}"
    end

    %__MODULE__{
      gepa_root: Path.expand(gepa_root),
      python: python,
      k: Keyword.get(opts, :k, 24),
      metadata:
        retrieval
        |> Map.take(["kind", "source_url", "corpus_checksum", "index_checksum"])
        |> Map.merge(%{
          "implementation" => "upstream_python_bm25s",
          "ranking_parity" => "source_exact",
          "upstream_commit" => @upstream_commit,
          "bm25s_version" => @bm25s_version
        })
    }
  end

  @impl true
  def call(%__MODULE__{} = retriever, inputs) do
    claim =
      inputs
      |> Map.new()
      |> Map.get(:claim, Map.get(Map.new(inputs), "claim", ""))

    case search(retriever, claim) do
      {:ok, docs} -> {:ok, Imp.Prediction.new(retrieved_docs: docs)}
      {:error, reason} -> {:error, reason}
    end
  end

  def search(%__MODULE__{} = retriever, query) do
    script = Path.expand("scripts/hover_bm25_upstream_eval.py")

    args = [
      script,
      "--gepa-root",
      retriever.gepa_root,
      "--query",
      query,
      "--k",
      Integer.to_string(retriever.k)
    ]

    case System.cmd(retriever.python, args, stderr_to_stdout: true) do
      {json, 0} ->
        {:ok, json |> Jason.decode!() |> Map.fetch!("retrieved_docs")}

      {output, status} ->
        {:error, {:hover_upstream_bm25_failed, status, output}}
    end
  end

  defp infer_gepa_root!(corpus_path) do
    marker = Path.join(["gepa_artifact", "benchmarks", "hover", "wiki.abstracts.2017.jsonl"])
    expanded = Path.expand(corpus_path)
    marker_suffix = Path.join(["", marker])

    if String.ends_with?(expanded, marker_suffix) do
      String.replace_suffix(expanded, marker_suffix, "")
    else
      raise ArgumentError,
            "could not infer GEPA root from HoVer corpus path #{inspect(corpus_path)}; set IMP_GEPA_ROOT"
    end
  end
end
