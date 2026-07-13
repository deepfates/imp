defmodule DSEx.BenchmarkTruth.HotpotMultiHopTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.{HotpotMultiHop, HoverBM25}
  alias DSEx.BenchmarkTruth.HoverBM25.UpstreamPython
  alias DSEx.{Module, Optimizer.Trace, Prediction, ProgramParameters}

  defp lm(parent) do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          send(parent, {:prompt, prompt})

          cond do
            prompt =~ "summary_2" ->
              %{reasoning: "The summaries identify the office.", answer: "Chief of Protocol"}

            prompt =~ "summary_1" ->
              %{
                reasoning: "Search for the actor's office.",
                query: "Shirley Temple government position"
              }

            prompt =~ "context" ->
              %{
                reasoning: "Combine the bridge and office.",
                summary: "Shirley Temple served as Chief of Protocol."
              }

            true ->
              %{
                reasoning: "Identify the actor named in the passage.",
                summary: "Corliss Archer was portrayed by Shirley Temple."
              }
          end
        end
      ]
    }
  end

  test "runs the source two-hop graph with k=7 and named traces" do
    parent = self()

    retriever = fn query, opts ->
      send(parent, {:retrieve, query, opts[:k]})

      if query =~ "Shirley Temple" do
        {:ok, [%{title: "Shirley Temple", text: "She served as Chief of Protocol."}]}
      else
        {:ok, [%{title: "Corliss Archer", text: "Portrayed by Shirley Temple."}]}
      end
    end

    program = HotpotMultiHop.new(lm(parent), retriever)
    assert program.k == 7

    :ok = Trace.start()

    assert {:ok, prediction} =
             Module.call(program, %{
               question: "What position was held by the woman who portrayed Corliss Archer?"
             })

    traces = Trace.finish()

    assert Prediction.get(prediction, :answer) == "Chief of Protocol"

    assert Prediction.get(prediction, :hop1_docs) == [
             "Corliss Archer | Portrayed by Shirley Temple."
           ]

    assert Prediction.get(prediction, :hop2_docs) == [
             "Shirley Temple | She served as Chief of Protocol."
           ]

    assert_receive {:retrieve,
                    "What position was held by the woman who portrayed Corliss Archer?", 7}

    assert_receive {:retrieve, "Shirley Temple government position", 7}

    assert Enum.map(traces, & &1.predictor) == [
             :summarize1,
             :create_query_hop2,
             :summarize2,
             :final_answer
           ]
  end

  test "exposes four independently optimizable predictors" do
    program = HotpotMultiHop.new(lm(self()), fn _query, _opts -> {:ok, []} end)

    assert Enum.map(ProgramParameters.predictors(program), & &1.name) == [
             :summarize1,
             :create_query_hop2,
             :summarize2,
             :final_answer
           ]

    updated =
      ProgramParameters.put_instruction(program, :create_query_hop2, "Find the bridge.")

    assert updated.create_query_hop2.predict.signature.instructions == "Find the bridge."
    refute updated.summarize1.predict.signature.instructions == "Find the bridge."
  end

  test "integration reuses only verified source-exact HoVer BM25s" do
    root = Path.join(System.tmp_dir!(), "hotpot-multi-hop-#{System.unique_integer([:positive])}")
    hover_dir = Path.join(root, "gepa_artifact/benchmarks/hover")
    corpus_path = Path.join(hover_dir, "wiki.abstracts.2017.jsonl")
    index_path = Path.join(hover_dir, "bm25s_retriever")
    File.mkdir_p!(index_path)
    File.write!(corpus_path, Jason.encode!(%{title: "A", text: ["B"]}) <> "\n")
    File.write!(Path.join(index_path, "params.json"), Jason.encode!(%{k1: 0.9, b: 0.4}))

    retrieval = %{
      "kind" => "bm25s_wiki_abstracts_2017",
      "status" => "present",
      "source_url" => "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
      "corpus_path" => corpus_path,
      "index_path" => index_path,
      "corpus_checksum" => "sha256:" <> HoverBM25.checksum_path(corpus_path),
      "index_checksum" => "sha256:" <> HoverBM25.checksum_path(index_path)
    }

    program = HotpotMultiHop.integration(lm(self()), retrieval, python: "python3")

    assert %UpstreamPython{
             k: 7,
             metadata: %{
               "implementation" => "upstream_python_bm25s",
               "ranking_parity" => "source_exact"
             }
           } = program.retriever

    assert %HotpotMultiHop{retrieval_source: %{"ranking_parity" => "source_exact"}} =
             HotpotMultiHop.integration(lm(self()), program.retriever)

    assert_raise ArgumentError, ~r/exact Hotpot retrieval unavailable/, fn ->
      HotpotMultiHop.integration(lm(self()), nil)
    end

    assert_raise ArgumentError, ~r/present HoVer/, fn ->
      HotpotMultiHop.integration(lm(self()), %{retrieval | "kind" => "colbert_v2"})
    end

    File.rm_rf!(root)
  end

  test "retrieval and passage failures stop the pipeline" do
    failed = HotpotMultiHop.new(lm(self()), fn _query, _opts -> {:error, :unavailable} end)

    assert {:error, {:hotpot_multi_hop_failed, :hop1, :unavailable}} =
             Module.call(failed, %{question: "question"})

    malformed = HotpotMultiHop.new(lm(self()), fn _query, _opts -> {:ok, [%{score: 1.0}]} end)

    assert {:error, {:hotpot_multi_hop_failed, :hop1, {:invalid_hotpot_passage, %{score: 1.0}}}} =
             Module.call(malformed, %{question: "question"})
  end
end
