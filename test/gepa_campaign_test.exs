defmodule GepaCampaignTest do
  use ExUnit.Case, async: false

  test "DSEx GEPA campaign writes partial dsex_gepa rows that merge into full evidence" do
    dataset_root = tmp_dir("gepa-campaign-data")
    upstream_dir = tmp_dir("gepa-campaign-upstream")
    rows_dir = tmp_dir("gepa-campaign-rows")
    final_dir = tmp_dir("gepa-campaign-final")

    write_dataset_root!(dataset_root)
    write_upstream_gepa_results!(upstream_dir, "gpt-41-mini")

    result =
      DSEx.BenchmarkTruth.GepaCampaign.run(
        dataset_root: dataset_root,
        campaign_id: "gepa-campaign-test",
        model: "openai:gpt-4.1-mini-2025-04-14",
        reflection_model: "openai:gpt-5",
        out_dir: rows_dir,
        seeds: [0, 1],
        generations: 1,
        pricing_source: "test provider usage export",
        token_cost: %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50},
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@abcdef1",
          "dsex" => "deepfates/dsex@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      )

    assert File.exists?(result.out_path)
    assert %{"rows" => rows} = File.read!(result.out_path) |> Jason.decode!()
    assert length(rows) == 6

    assert Enum.all?(rows, fn row ->
             is_map(get_in(row, ["results", "dsex_gepa"])) and
               get_in(row, ["results", "dsex_gepa", "source"]) =~ "DSEx GEPA campaign runner" and
               is_map(row["dataset"]) and
               is_map(row["token_cost"]) and
               row["seed_variance"]["seeds"] == [0, 1]
           end)

    hover = Enum.find(rows, &(&1["family"] == "hoverBench"))
    assert get_in(hover, ["dataset", "retrieval", "kind"]) == "bm25s_wiki_abstracts_2017"
    assert get_in(hover, ["dataset", "retrieval", "corpus_checksum"]) =~ "sha256:"
    assert get_in(hover, ["dataset", "retrieval", "index_checksum"]) =~ "sha256:"

    Mix.Task.reenable("dsex.benchmark.gepa_replication")

    Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
      "--from-gepa-artifact",
      upstream_dir,
      "--dsex-input",
      result.out_path,
      "--campaign-id",
      "gepa-campaign-test",
      "--artifact-model",
      "gpt-41-mini",
      "--out",
      final_dir
    ])

    [path] = Path.wildcard(Path.join(final_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["full_gepa_replication"]
    assert DSEx.BenchmarkTruth.GepaReplicationContract.full_artifact?(artifact)
  end

  test "DSEx GEPA campaign rejects HoVer rows without source-exact retrieval provenance" do
    dataset_root = tmp_dir("gepa-campaign-hover-missing-retrieval")
    rows_dir = tmp_dir("gepa-campaign-hover-missing-rows")
    write_dataset_root!(dataset_root)

    families_path = Path.join(dataset_root, "families.json")

    families =
      families_path
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["families"], fn families ->
        Enum.map(families, fn
          %{"family" => "hoverBench"} = spec -> Map.delete(spec, "retrieval")
          spec -> spec
        end)
      end)

    File.write!(families_path, Jason.encode!(families))

    assert_raise ArgumentError,
                 ~r/hoverBench row requires source-exact BM25\/wiki retrieval provenance/,
                 fn ->
                   DSEx.BenchmarkTruth.GepaCampaign.run(
                     dataset_root: dataset_root,
                     campaign_id: "gepa-campaign-hover-missing-retrieval",
                     model: "openai:gpt-4.1-mini-2025-04-14",
                     reflection_model: "openai:gpt-5",
                     out_dir: rows_dir,
                     seeds: [0],
                     generations: 1,
                     pricing_source: "test provider usage export",
                     token_cost: %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50},
                     source_commits: %{
                       "dspy" => "stanfordnlp/dspy@abcdef1",
                       "dsex" => "deepfates/dsex@abcdef2",
                       "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
                     },
                     lm: static_gold_lm()
                   )
                 end
  end

  defp static_gold_lm do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

          cond do
            prompt =~ "num_pii_leaked" -> %{reasoning: "No PII leaked.", num_pii_leaked: 0}
            prompt =~ "judgment" -> %{reasoning: "Response A is good enough.", judgment: true}
            prompt =~ "llm_request" -> %{llm_request: "redacted request", response: "gold"}
            prompt =~ "retrieved_docs" -> %{retrieved_docs: ["gold | supporting document"]}
            prompt =~ "response" -> %{response: "gold"}
            true -> %{answer: "42"}
          end
        end
      ]
    }
  end

  defp write_dataset_root!(root) do
    families =
      Enum.map(family_programs(), fn {family, program, budget} ->
        family_dir = Path.join(root, family)
        File.mkdir_p!(family_dir)

        spec =
          if family == "Papillon" do
            Enum.each(["train", "dev", "test"], fn split ->
              File.write!(
                Path.join(family_dir, "#{split}.jsonl"),
                Jason.encode!(%{
                  user_query: "#{family} #{split} query",
                  target_response: "gold",
                  pii_str: "secret@example.com"
                }) <> "\n"
              )
            end)

            %{
              "family" => family,
              "program" => program,
              "signature" => "user_query -> llm_request, response",
              "instructions" =>
                "Answer the user query while preserving privacy-sensitive information.",
              "input_keys" => ["user_query"],
              "output_key" => "response",
              "metric_calls" => budget,
              "upstream_metric" => "papillon_utils.compute_overall_score"
            }
          else
            contract = campaign_contract(family)

            Enum.each(["train", "dev", "test"], fn split ->
              File.write!(
                Path.join(family_dir, "#{split}.jsonl"),
                campaign_record(family, split) <> "\n"
              )
            end)

            %{
              "family" => family,
              "program" => program,
              "signature" => contract.signature,
              "instructions" => "Answer the question.",
              "input_keys" => contract.input_keys,
              "output_key" => contract.output_key,
              "metric_calls" => budget,
              "upstream_metric" => contract.upstream_metric,
              "retrieval" => Map.get(contract, :retrieval)
            }
          end

        spec
      end)

    File.write!(Path.join(root, "families.json"), Jason.encode!(%{"families" => families}))
  end

  defp campaign_record("hoverBench", split) do
    Jason.encode!(%{
      claim: "hoverBench #{split} claim",
      supporting_facts: [%{key: "gold"}],
      label: "SUPPORTED"
    })
  end

  defp campaign_record("AIMEBench", split) do
    Jason.encode!(%{problem: "AIMEBench #{split} problem", answer: "42"})
  end

  defp campaign_record("HotpotQABench", split) do
    Jason.encode!(%{question: "HotpotQABench #{split} question", answer: "42"})
  end

  defp campaign_record("IFBench", split) do
    Jason.encode!(%{
      prompt: "IFBench #{split} prompt",
      instruction_id_list: ["keywords:existence"],
      kwargs: [%{keywords: ["gold"]}]
    })
  end

  defp campaign_record("LiveBenchMathBench", split) do
    Jason.encode!(%{
      question: "LiveBenchMathBench #{split} question",
      answer: "42",
      question_d: %{
        task: "aime",
        subtask: "aime_2024",
        turns: ["LiveBenchMathBench #{split} question"],
        ground_truth: "42",
        question_id: "livebench-#{split}"
      }
    })
  end

  defp campaign_record(family, split) do
    raise ArgumentError, "unknown campaign fixture #{inspect({family, split})}"
  end

  defp campaign_contract("AIMEBench") do
    %{
      signature: "problem -> answer",
      input_keys: ["problem"],
      output_key: "answer",
      upstream_metric: "AIME.metric integer exact match"
    }
  end

  defp campaign_contract("HotpotQABench") do
    %{
      signature: "question -> answer",
      input_keys: ["question"],
      output_key: "answer",
      upstream_metric: "dspy.evaluate.answer_exact_match"
    }
  end

  defp campaign_contract("hoverBench") do
    %{
      signature: "claim -> retrieved_docs",
      input_keys: ["claim"],
      output_key: "retrieved_docs",
      upstream_metric: "hover_utils.discrete_retrieval_eval",
      retrieval: %{
        "kind" => "bm25s_wiki_abstracts_2017",
        "status" => "present",
        "source_url" =>
          "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
        "corpus_path" => "test/fixtures/hover/wiki.abstracts.2017.jsonl",
        "index_path" => "test/fixtures/hover/bm25s_retriever",
        "corpus_checksum" =>
          "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "index_checksum" =>
          "sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
    }
  end

  defp campaign_contract("IFBench") do
    %{
      signature: "prompt -> response",
      input_keys: ["prompt"],
      output_key: "response",
      upstream_metric: "IFBench.ifbench_metric.metric"
    }
  end

  defp campaign_contract("LiveBenchMathBench") do
    %{
      signature: "question -> answer",
      input_keys: ["question"],
      output_key: "answer",
      upstream_metric: "livebench_math.calculate_livebench_score"
    }
  end

  defp write_upstream_gepa_results!(artifact_dir, model) do
    Enum.each(family_programs(), fn {family, program, _budget} ->
      Enum.each([{"Baseline", 0.5}, {"GEPA", 0.6}, {"MIPROv2-Heavy", 0.55}], fn {optimizer, score} ->
        run_dir =
          Path.join([
            artifact_dir,
            "experiment_runs",
            "seed_0",
            "#{family}_#{program}_#{optimizer}_#{model}",
            "evaluation_results"
          ])

        File.mkdir_p!(run_dir)

        File.write!(
          Path.join(run_dir, "evaluation_result.txt"),
          "score,cost,input_tokens,output_tokens\n#{score},0.25,1000,200\n"
        )
      end)
    end)
  end

  defp family_programs do
    [
      {"AIMEBench", "CoT", 1839},
      {"HotpotQABench", "HotpotMultiHop", 6871},
      {"hoverBench", "HoverMultiHop", 7051},
      {"IFBench", "IFBenchCoT2StageProgram", 3593},
      {"LiveBenchMathBench", "CoT", 1839},
      {"Papillon", "PAPILLON", 2426}
    ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
