defmodule HoverBM25ParityTest do
  use ExUnit.Case, async: true

  test "native HoVer BM25 retrieves supporting titles from a pinned corpus" do
    {corpus_path, index_path} = tmp_retrieval!()

    retriever =
      Imp.BenchmarkTruth.HoverBM25.new(retrieval(corpus_path, index_path))

    assert retriever.metadata["ranking_parity"] == "approximate"
    assert retriever.metadata["implementation"] == "imp_native_bm25_approximation"

    {:ok, prediction} =
      Imp.Module.call(retriever, %{claim: "The Eiffel Tower is located in Paris."})

    assert ["Paris | " <> _rest | _] = Imp.Prediction.get(prediction, :retrieved_docs)
  end

  test "HoVer retrieval rejects declared checksums that do not match source bytes" do
    {corpus_path, index_path} = tmp_retrieval!()
    retrieval = retrieval(corpus_path, index_path)
    File.write!(corpus_path, File.read!(corpus_path) <> "changed\n")

    assert_raise ArgumentError, ~r/corpus_checksum mismatch/, fn ->
      Imp.BenchmarkTruth.HoverBM25.new(retrieval)
    end
  end

  test "frozen-claim fingerprint is canonical, ordered, and excludes test" do
    root = temporary_path("fingerprint")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    train = Jason.encode!(%{"claim" => "Train claim"}) <> "\n"
    dev = Jason.encode!(%{"claim" => "Dev claim"}) <> "\n"
    File.write!(Path.join(root, "train.jsonl"), train)
    File.write!(Path.join(root, "dev.jsonl"), dev)
    File.write!(Path.join(root, "test.jsonl"), "must-not-be-read\n")
    corpus = Path.join(root, "corpus.jsonl")

    File.write!(
      corpus,
      Enum.map_join(["Zero", "One", "Two"], "\n", &Jason.encode!(%{"title" => &1})) <>
        "\n"
    )

    python = ~S"""
    import contextlib, importlib.util, io, pathlib, sys
    module_path, root, corpus, train_sha, dev_sha = sys.argv[1:]
    spec = importlib.util.spec_from_file_location("hover_eval", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    class BM25:
        @staticmethod
        def tokenize(claims, **_kwargs):
            assert claims == ["Train claim", "Dev claim"]
            return claims
    class Retriever:
        def retrieve(self, _tokens, **kwargs):
            assert kwargs == {"k": 2, "n_threads": 1, "show_progress": False}
            return [[2, 0], [1, 2]], [[1.0, 0.5], [1.0, 0.5]]
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        module.emit_frozen_claim_retrieval_fingerprint(
            Retriever(), object(), pathlib.Path(corpus), pathlib.Path(root), BM25,
            split_specs=(("train", 1, train_sha), ("dev", 1, dev_sha)), k=2)
    sys.stdout.write(output.getvalue())
    """

    args = [
      "-c",
      python,
      Path.expand("scripts/hover_bm25_upstream_eval.py"),
      root,
      corpus,
      sha256(train),
      sha256(dev)
    ]

    {output, 0} = System.cmd("python3", args)
    {repeat, 0} = System.cmd("python3", args)
    assert repeat == output
    assert String.ends_with?(output, "\n")
    records = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(records, &{&1["split"], &1["split_position"]}) ==
             [{"train", 0}, {"dev", 0}]

    assert Enum.map(records, & &1["titles"]) == [["Two", "Zero"], ["One", "Two"]]
    assert Enum.map(records, & &1["doc_ids"]) == [[2, 0], [1, 2]]
    assert Enum.map(records, & &1["row_sha256"]) == [sha256(train), sha256(dev)]
    refute Enum.any?(records, &Map.has_key?(&1, "scores"))

    File.write!(Path.join(root, "train.jsonl"), train <> "changed\n")
    {error, 1} = System.cmd("python3", args, stderr_to_stdout: true)
    assert error =~ "HoVer frozen train bytes differ"
  end

  test "source-exact HoVer adapter matches pinned upstream bm25s title order" do
    if System.get_env("IMP_HOVER_UPSTREAM_PARITY") == "1" do
      gepa_root = Path.expand(System.get_env("IMP_GEPA_ROOT") || "tmp/gepa-artifact")
      python = System.get_env("IMP_GEPA_PYTHON") || "python3"

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
        "imp-hover-retrieval-#{System.unique_integer([:positive])}"
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
      "corpus_checksum" => "sha256:" <> Imp.BenchmarkTruth.HoverBM25.checksum_path(corpus_path),
      "index_checksum" => "sha256:" <> Imp.BenchmarkTruth.HoverBM25.checksum_path(index_path)
    }
  end

  defp temporary_path(name) do
    Path.join(System.tmp_dir!(), "imp-hover-#{name}-#{System.unique_integer([:positive])}")
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

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
