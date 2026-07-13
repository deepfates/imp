defmodule HoverBM25ParityTest do
  use ExUnit.Case, async: true

  test "native HoVer BM25 retrieves supporting titles from a pinned corpus" do
    {corpus_path, index_path} = tmp_retrieval!()

    retriever =
      DSEx.BenchmarkTruth.HoverBM25.new(retrieval(corpus_path, index_path))

    {:ok, prediction} =
      DSEx.Module.call(retriever, %{claim: "The Eiffel Tower is located in Paris."})

    assert ["Paris | " <> _rest | _] = DSEx.Prediction.get(prediction, :retrieved_docs)
  end

  test "HoVer retrieval rejects declared checksums that do not match source bytes" do
    {corpus_path, index_path} = tmp_retrieval!()
    retrieval = retrieval(corpus_path, index_path)
    File.write!(corpus_path, File.read!(corpus_path) <> "changed\n")

    assert_raise ArgumentError, ~r/corpus_checksum mismatch/, fn ->
      DSEx.BenchmarkTruth.HoverBM25.new(retrieval)
    end
  end

  test "native HoVer BM25 can be compared with upstream bm25s when explicitly enabled" do
    if System.get_env("DSEX_HOVER_UPSTREAM_PARITY") == "1" do
      gepa_root = Path.expand("tmp/gepa-artifact")

      corpus_path =
        Path.join(gepa_root, "gepa_artifact/benchmarks/hover/wiki.abstracts.2017.jsonl")

      index_path =
        Path.join(gepa_root, "gepa_artifact/benchmarks/hover/bm25s_retriever")

      unless File.exists?(corpus_path) do
        raise "HoVer upstream corpus is missing at #{corpus_path}"
      end

      query =
        System.get_env("DSEX_HOVER_UPSTREAM_QUERY") || "The Eiffel Tower is located in Paris."

      k = String.to_integer(System.get_env("DSEX_HOVER_UPSTREAM_K") || "7")

      {json, 0} =
        System.cmd("python3", [
          "scripts/hover_bm25_upstream_eval.py",
          "--gepa-root",
          gepa_root,
          "--query",
          query,
          "--k",
          Integer.to_string(k)
        ])

      upstream_titles = json |> Jason.decode!() |> Map.fetch!("titles")

      dsex_titles =
        DSEx.BenchmarkTruth.HoverBM25.new(
          retrieval(corpus_path, index_path),
          k: k
        )
        |> DSEx.BenchmarkTruth.HoverBM25.retrieve(query)
        |> Enum.map(& &1.title)

      assert dsex_titles == upstream_titles
    else
      assert :skipped
    end
  end

  defp tmp_retrieval! do
    root =
      Path.join(
        System.tmp_dir!(),
        "dsex-hover-retrieval-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    corpus_path = Path.join(root, "corpus.jsonl")
    index_path = Path.join(root, "index")
    File.mkdir_p!(index_path)
    File.write!(Path.join(index_path, "params.json"), Jason.encode!(%{k1: 0.9, b: 0.4}))

    File.write!(
      corpus_path,
      Enum.map_join(
        [
          %{title: "Paris", text: ["The Eiffel Tower is a landmark in Paris."]},
          %{title: "Berlin", text: ["The Brandenburg Gate is in Berlin."]}
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    {corpus_path, index_path}
  end

  defp retrieval(corpus_path, index_path) do
    %{
      "kind" => "bm25s_wiki_abstracts_2017",
      "corpus_path" => corpus_path,
      "index_path" => index_path,
      "corpus_checksum" => "sha256:" <> DSEx.BenchmarkTruth.HoverBM25.checksum_path(corpus_path),
      "index_checksum" => "sha256:" <> DSEx.BenchmarkTruth.HoverBM25.checksum_path(index_path)
    }
  end
end
