defmodule HoverBM25ParityTest do
  use ExUnit.Case, async: true

  test "native HoVer BM25 retrieves supporting titles from a pinned corpus" do
    {corpus_path, index_path} = tmp_retrieval!()

    retriever =
      DSEx.BenchmarkTruth.HoverBM25.new(retrieval(corpus_path, index_path))

    assert retriever.metadata["ranking_parity"] == "approximate"
    assert retriever.metadata["implementation"] == "dsex_native_bm25_approximation"

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

  test "source-exact HoVer adapter matches pinned upstream bm25s title order" do
    if System.get_env("DSEX_HOVER_UPSTREAM_PARITY") == "1" do
      gepa_root = Path.expand(System.get_env("DSEX_GEPA_ROOT") || "tmp/gepa-artifact")
      python = System.get_env("DSEX_GEPA_PYTHON") || "python3"

      corpus_path =
        Path.join(gepa_root, "gepa_artifact/benchmarks/hover/wiki.abstracts.2017.jsonl")

      index_path =
        Path.join(gepa_root, "gepa_artifact/benchmarks/hover/bm25s_retriever")

      unless File.exists?(corpus_path) do
        raise "HoVer upstream corpus is missing at #{corpus_path}"
      end

      unless File.dir?(index_path) do
        raise "HoVer upstream index is missing at #{index_path}"
      end

      for {query, expected_titles} <- upstream_title_fixtures() do
        {json, 0} =
          System.cmd(python, [
            "scripts/hover_bm25_upstream_eval.py",
            "--gepa-root",
            gepa_root,
            "--query",
            query,
            "--k",
            Integer.to_string(length(expected_titles))
          ])

        result = Jason.decode!(json)
        assert result["upstream_commit"] == "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"

        assert result["upstream_source_sha256"] ==
                 "705a1d4fa5452d66d21c00d8d915d5dcd57e820b077a68bf3786407d040d3522"

        assert result["bm25s_version"] == "0.2.12"
        assert result["titles"] == expected_titles
        assert length(result["scores"]) == length(expected_titles)
      end
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

  defp upstream_title_fixtures do
    [
      {"The Eiffel Tower is located in Paris.",
       [
         "Eiffel Tower (Paris, Texas)",
         "Eiffel Tower (Paris, Tennessee)",
         "Eiffel Tower",
         "Eiffel Tower (disambiguation)",
         "Eiffel Tower (Cedar Fair)"
       ]},
      {"Ada Lovelace worked on the Analytical Engine.",
       [
         "Ada Lovelace",
         "The Thrilling Adventures of Lovelace and Babbage",
         "Ada Lovelace Award",
         "History of women in engineering",
         "Ada. National College for Digital Skills"
       ]},
      {"The Beatles were formed in Liverpool.",
       [
         "The Beatles timeline",
         "Liverpool poets",
         "Songs We Remember",
         "Cultural impact of the Beatles",
         "Kingsize Taylor and the Dominoes"
       ]}
    ]
  end
end
