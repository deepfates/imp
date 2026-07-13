defmodule GepaCampaignTest do
  use ExUnit.Case, async: false

  test "DSEx GEPA campaign keeps local HoVer retrieval out of full replication evidence" do
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
        token_cost:
          explicit_costs(
            DSEx.BenchmarkTruth.GepaReplicationContract.required_families(),
            [0, 1]
          ),
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
               row["dataset"]["scope"] == "full" and
               row["dataset"]["split_counts"] == %{"train" => 2, "dev" => 2, "test" => 2} and
               is_map(row["token_cost"]) and
               row["seed_variance"]["seeds"] == [0, 1]
           end)

    hover = Enum.find(rows, &(&1["family"] == "hoverBench"))
    assert get_in(hover, ["dataset", "retrieval", "kind"]) == "bm25s_wiki_abstracts_2017"
    assert get_in(hover, ["dataset", "retrieval", "corpus_checksum"]) =~ "sha256:"
    assert get_in(hover, ["dataset", "retrieval", "index_checksum"]) =~ "sha256:"
    assert get_in(hover, ["dataset", "retrieval", "verified"]) == true
    assert get_in(hover, ["dataset", "retrieval", "implementation"]) == "dsex_local_bm25"
    assert get_in(hover, ["results", "dsex_gepa", "score"]) == 1.0

    Mix.Task.reenable("dsex.benchmark.gepa_replication")

    assert_raise Mix.Error, ~r/GEPA replication artifact is incomplete/, fn ->
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
    end

    [path] = Path.wildcard(Path.join(final_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    refute artifact["summary"]["full_gepa_replication"]
    refute DSEx.BenchmarkTruth.GepaReplicationContract.full_artifact?(artifact)
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
                     families: ["hoverBench"],
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

  test "DSEx GEPA campaign can write resumable partial family rows" do
    dataset_root = tmp_dir("gepa-campaign-partial-data")
    rows_dir = tmp_dir("gepa-campaign-partial-rows")
    write_dataset_root!(dataset_root)

    result =
      DSEx.BenchmarkTruth.GepaCampaign.run(
        dataset_root: dataset_root,
        campaign_id: "gepa-campaign-partial-test",
        model: "openai:gpt-4.1-mini-2025-04-14",
        reflection_model: "openai:gpt-5",
        out_dir: rows_dir,
        families: ["AIMEBench"],
        seeds: [0, 1],
        generations: 1,
        pricing_source: "test provider usage export",
        token_cost: explicit_costs(["AIMEBench"], [0, 1]),
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@abcdef1",
          "dsex" => "deepfates/dsex@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      )

    assert %{"summary" => summary, "rows" => [%{"family" => "AIMEBench"}]} =
             File.read!(result.out_path) |> Jason.decode!()

    assert summary["partial"]
    assert summary["families"] == ["AIMEBench"]
    assert summary["max_concurrency"] == 1

    [row] = result.report["rows"]
    assert row["token_cost"]["usd"] == 0.02
    assert row["token_cost"]["input_tokens"] == 200
    assert Enum.map(row["token_cost"]["breakdown"], & &1["seed"]) == [0, 1]
  end

  test "DSEx GEPA campaign rejects one fallback cost tuple for multiple seeds" do
    dataset_root = tmp_dir("gepa-campaign-ambiguous-cost-data")
    rows_dir = tmp_dir("gepa-campaign-ambiguous-cost-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        seeds: [0, 1],
        token_cost: %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50}
      )

    assert_raise ArgumentError, ~r/require token_cost keyed by family and seed/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(opts)
    end
  end

  test "DSEx GEPA campaign rejects unknown partial family names" do
    dataset_root = tmp_dir("gepa-campaign-unknown-family")
    rows_dir = tmp_dir("gepa-campaign-unknown-family-rows")
    write_dataset_root!(dataset_root)

    assert_raise ArgumentError, ~r/unknown DSEx GEPA campaign families: MissingBench/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(
        dataset_root: dataset_root,
        campaign_id: "gepa-campaign-unknown-family-test",
        model: "openai:gpt-4.1-mini-2025-04-14",
        reflection_model: "openai:gpt-5",
        out_dir: rows_dir,
        families: ["MissingBench"],
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

  test "DSEx GEPA campaign resumes completed seeds without calling the LM again" do
    dataset_root = tmp_dir("gepa-campaign-resume-data")
    rows_dir = tmp_dir("gepa-campaign-resume-rows")
    write_dataset_root!(dataset_root)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    events = self()

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, opts ->
        Agent.update(calls, &(&1 + 1))
        static_gold_handler(messages, opts)
      end)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-resume-test",
        seeds: [0, 1],
        token_cost: explicit_costs(["AIMEBench"], [0, 1]),
        lm: lm,
        reporter: &send(events, &1)
      )

    first = DSEx.BenchmarkTruth.GepaCampaign.run(opts)
    first_calls = Agent.get(calls, & &1)
    assert first_calls > 0

    second = DSEx.BenchmarkTruth.GepaCampaign.run(opts)
    assert Agent.get(calls, & &1) == first_calls
    assert first.report["rows"] == second.report["rows"]
    assert_received %{event: :seed_resumed, family: "AIMEBench", seed: 0}
    assert_received %{event: :seed_resumed, family: "AIMEBench", seed: 1}

    [checkpoint] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    assert %{"completed" => completed} = checkpoint |> File.read!() |> Jason.decode!()
    assert Enum.map(completed, & &1["seed"]) == [0, 1]
  end

  test "DSEx GEPA campaign consumes and clears persisted optimizer generation state" do
    dataset_root = tmp_dir("gepa-campaign-generation-resume-data")
    rows_dir = tmp_dir("gepa-campaign-generation-resume-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-generation-resume",
        generations: 2
      )

    DSEx.BenchmarkTruth.GepaCampaign.run(opts)

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    [completed] = checkpoint["completed"]

    [spec | _] =
      dataset_root
      |> Path.join("families.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("families")

    artifact =
      DSEx.Optimize.Anything.new_artifact(:instruction, spec["instructions"])

    receiver = self()

    DSEx.Optimize.GEPA.optimize(
      artifact,
      fn _artifact, examples ->
        %{per_example_scores: Enum.map(examples, fn _example -> 1.0 end)}
      end,
      examples: [:dev_one, :dev_two],
      generations: 1,
      mutation_fn: fn _artifact, _asi, _generation -> "checkpointed mutation" end,
      checkpoint_fn: fn state ->
        send(receiver, {:optimizer_checkpoint, state})
        :ok
      end
    )

    assert_receive {:optimizer_checkpoint, _baseline_state}
    assert_receive {:optimizer_checkpoint, optimizer_state}

    interrupted =
      checkpoint
      |> Map.put("completed", [])
      |> Map.put("in_progress", %{
        "0" => %{
          "baseline" => %{
            "train" => get_in(completed, ["result", "baseline_train"]),
            "dev" => get_in(completed, ["result", "baseline_dev"]),
            "test" => get_in(completed, ["result", "baseline_test"])
          },
          "optimizer_state" => optimizer_state,
          "usage" => %{"usd" => 0.5, "input_tokens" => 50, "output_tokens" => 25}
        }
      })

    File.write!(checkpoint_path, Jason.encode!(interrupted))

    assert %{
             "0" => %{
               "baseline" => %{"train" => _, "dev" => _, "test" => _},
               "optimizer_state" => %{"candidates" => candidates}
             }
           } = interrupted["in_progress"]

    assert Enum.map(candidates, & &1["id"]) == ["baseline", "gepa-1"]
    assert interrupted["completed"] == []

    usage_lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, handler_opts ->
        :telemetry.execute(
          [:req_llm, :token_usage],
          %{total_cost: 0.001, tokens: %{input_tokens: 10, output_tokens: 5}},
          %{}
        )

        static_gold_handler(messages, handler_opts)
      end)

    result = opts |> Keyword.put(:lm, usage_lm) |> DSEx.BenchmarkTruth.GepaCampaign.run()

    assert [
             %{
               "results" => %{"dsex_gepa" => %{"candidate_count" => count}},
               "token_cost" => token_cost
             }
           ] =
             result.report["rows"]

    assert count >= 3
    assert token_cost["usd"] > 0.5
    assert token_cost["input_tokens"] > 50
    assert token_cost["output_tokens"] > 25

    resumed = checkpoint_path |> File.read!() |> Jason.decode!()
    assert resumed["in_progress"] == %{}
    assert Enum.map(resumed["completed"], & &1["seed"]) == [0]
  end

  test "DSEx GEPA campaign rejects checkpoint configuration and dataset mismatches" do
    dataset_root = tmp_dir("gepa-campaign-checkpoint-identity-data")
    rows_dir = tmp_dir("gepa-campaign-checkpoint-identity-rows")
    write_dataset_root!(dataset_root)

    opts = campaign_opts(dataset_root, rows_dir, campaign_id: "gepa-checkpoint-identity")
    DSEx.BenchmarkTruth.GepaCampaign.run(opts)

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(Keyword.put(opts, :generations, 2))
    end

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(
        Keyword.put(opts, :execution, %{"lm" => %{"max_tokens" => 512}})
      )
    end

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    [entry] = checkpoint["completed"]

    malformed =
      checkpoint
      |> Map.put("completed", [entry, entry])

    File.write!(checkpoint_path, Jason.encode!(malformed))

    assert_raise ArgumentError, ~r/duplicate seed entries in GEPA checkpoint/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(opts)
    end

    File.write!(checkpoint_path, Jason.encode!(checkpoint))

    File.write!(
      Path.join([dataset_root, "AIMEBench", "train.jsonl"]),
      Jason.encode!(%{problem: "changed", answer: "42"}) <> "\n"
    )

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      DSEx.BenchmarkTruth.GepaCampaign.run(opts)
    end
  end

  defp static_gold_lm do
    %{
      module: DSEx.LM.Static,
      opts: [handler: &static_gold_handler/2]
    }
  end

  defp static_gold_handler(messages, _opts) do
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

  defp campaign_opts(dataset_root, rows_dir, overrides) do
    Keyword.merge(
      [
        dataset_root: dataset_root,
        campaign_id: "gepa-campaign-checkpoint-test",
        model: "openai:gpt-4.1-mini-2025-04-14",
        reflection_model: "openai:gpt-5",
        out_dir: rows_dir,
        families: ["AIMEBench"],
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
      ],
      overrides
    )
  end

  defp explicit_costs(families, seeds) do
    Map.new(families, fn family ->
      {family,
       Map.new(seeds, fn seed ->
         {Integer.to_string(seed), %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50}}
       end)}
    end)
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
                Enum.map_join(1..2, "\n", fn index ->
                  Jason.encode!(%{
                    user_query: "#{family} #{split} query #{index}",
                    target_response: "gold",
                    pii_str: "secret#{index}@example.com"
                  })
                end) <> "\n"
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
            contract = campaign_contract(family, family_dir)

            Enum.each(["train", "dev", "test"], fn split ->
              File.write!(
                Path.join(family_dir, "#{split}.jsonl"),
                Enum.map_join(1..2, "\n", fn index -> campaign_record(family, split, index) end) <>
                  "\n"
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

        Map.merge(spec, %{
          "dataset_scope" => "full",
          "max_per_split" => nil,
          "split_counts" => %{"train" => 2, "dev" => 2, "test" => 2}
        })
      end)

    File.write!(Path.join(root, "families.json"), Jason.encode!(%{"families" => families}))
  end

  defp campaign_record("hoverBench", split, index) do
    Jason.encode!(%{
      claim: "hoverBench #{split} claim #{index}",
      supporting_facts: [%{key: "gold"}],
      label: "SUPPORTED"
    })
  end

  defp campaign_record("AIMEBench", split, index) do
    Jason.encode!(%{problem: "AIMEBench #{split} problem #{index}", answer: "42"})
  end

  defp campaign_record("HotpotQABench", split, index) do
    Jason.encode!(%{question: "HotpotQABench #{split} question #{index}", answer: "42"})
  end

  defp campaign_record("IFBench", split, index) do
    Jason.encode!(%{
      prompt: "IFBench #{split} prompt #{index}",
      instruction_id_list: ["keywords:existence"],
      kwargs: [%{keywords: ["gold"]}]
    })
  end

  defp campaign_record("LiveBenchMathBench", split, index) do
    Jason.encode!(%{
      question: "LiveBenchMathBench #{split} question #{index}",
      answer: "42",
      question_d: %{
        task: "aime",
        subtask: "aime_2024",
        turns: ["LiveBenchMathBench #{split} question #{index}"],
        ground_truth: "42",
        question_id: "livebench-#{split}-#{index}"
      }
    })
  end

  defp campaign_record(family, split, index) do
    raise ArgumentError, "unknown campaign fixture #{inspect({family, split, index})}"
  end

  defp campaign_contract("AIMEBench", _family_dir) do
    %{
      signature: "problem -> answer",
      input_keys: ["problem"],
      output_key: "answer",
      upstream_metric: "AIME.metric integer exact match"
    }
  end

  defp campaign_contract("HotpotQABench", _family_dir) do
    %{
      signature: "question -> answer",
      input_keys: ["question"],
      output_key: "answer",
      upstream_metric: "dspy.evaluate.answer_exact_match"
    }
  end

  defp campaign_contract("hoverBench", family_dir) do
    corpus_path = Path.join(family_dir, "wiki.abstracts.2017.jsonl")
    index_dir = Path.join(family_dir, "bm25s_retriever")
    File.mkdir_p!(index_dir)

    File.write!(
      corpus_path,
      Enum.map_join(
        [
          %{title: "gold", text: ["supporting document for hoverBench claims"]},
          %{title: "distractor", text: ["unrelated astronomy note"]}
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    File.write!(Path.join(index_dir, "params.json"), Jason.encode!(%{k1: 0.9, b: 0.4}))

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
        "corpus_path" => corpus_path,
        "index_path" => index_dir,
        "corpus_checksum" =>
          "sha256:" <> DSEx.BenchmarkTruth.HoverBM25.checksum_path(corpus_path),
        "index_checksum" => "sha256:" <> DSEx.BenchmarkTruth.HoverBM25.checksum_path(index_dir)
      }
    }
  end

  defp campaign_contract("IFBench", _family_dir) do
    %{
      signature: "prompt -> response",
      input_keys: ["prompt"],
      output_key: "response",
      upstream_metric: "IFBench.ifbench_metric.metric"
    }
  end

  defp campaign_contract("LiveBenchMathBench", _family_dir) do
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
