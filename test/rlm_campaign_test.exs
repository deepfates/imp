defmodule DSEx.BenchmarkTruth.RLMCampaignTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.{RLMCampaign, RLMCheckpoint, RLMProtocol, RLMStatistics}

  defmodule GoodRuntime do
    @behaviour DSEx.BenchmarkTruth.RLMRuntime
    def execute(row, approach, _context) do
      if Map.has_key?(row, "gold") or Map.has_key?(row, "evidence_document_ids"),
        do: raise("gold leaked into runtime payload")

      {:ok,
       %{
         "answer" => "yes",
         "latency_ms" => 1.0,
         "usage" => %{
           "requests" => 1,
           "root_calls" => 1,
           "sub_calls" => 0,
           "input_tokens" => 1,
           "output_tokens" => 1,
           "usd" => 0.0
         },
         "trace_shape" => [approach],
         "trace" => [],
         "call_semantics" => %{
           "provider_calls" => 1,
           "root_calls" => 1,
           "sub_calls" => 0,
           "max_llm_calls_scope" =>
             if(approach == "rlm", do: "total_provider_calls", else: "not_applicable"),
           "configured_max_depth" => if(approach == "rlm", do: 1, else: 0),
           "max_observed_depth" => 0
         }
       }}
    end
  end

  defmodule CrashRuntime do
    @behaviour DSEx.BenchmarkTruth.RLMRuntime
    def execute(_row, _approach, _context), do: raise("ambiguous dispatch")
  end

  defmodule MalformedRuntime do
    @behaviour DSEx.BenchmarkTruth.RLMRuntime
    def execute(_row, _approach, _context),
      do:
        {:ok,
         %{
           "latency_ms" => 1.0,
           "usage" => %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0},
           "trace_shape" => ["bad"],
           "trace" => []
         }}
  end

  defmodule OverBudgetRuntime do
    @behaviour DSEx.BenchmarkTruth.RLMRuntime
    def execute(_row, approach, _context),
      do:
        {:ok,
         %{
           "answer" => "yes",
           "latency_ms" => 1.0,
           "usage" => %{
             "requests" => 2,
             "root_calls" => 2,
             "sub_calls" => 0,
             "input_tokens" => 1,
             "output_tokens" => 1,
             "usd" => 0.0
           },
           "trace_shape" => [approach],
           "trace" => [],
           "call_semantics" => %{
             "provider_calls" => 2,
             "root_calls" => 2,
             "sub_calls" => 0,
             "max_llm_calls_scope" => "not_applicable",
             "configured_max_depth" => 0,
             "max_observed_depth" => 0
           }
         }}
  end

  test "five adapters run without exposing gold and committed rows resume without replay" do
    fixture = fixture!()
    result = run!(fixture, GoodRuntime)
    assert result.artifact["evidence_tier"] == "t2_live_sample"
    assert result.artifact["summary"]["total"] == 20
    assert result.artifact["summary"]["all_passing"]
    refute result.artifact["summary"]["paper_protocol_complete"]

    resumed = run!(fixture, CrashRuntime)
    assert resumed.artifact["summary"]["total"] == 20
    assert resumed.artifact["summary"]["all_passing"]
  end

  test "dataset drift is rejected before dispatch" do
    fixture = fixture!()
    File.write!(fixture.dataset_paths["s_niah"], "{}\n", [:append])

    assert_raise ArgumentError, ~r/dataset hash mismatch for s_niah/, fn ->
      run!(fixture, GoodRuntime)
    end
  end

  test "ambiguous dispatch is durable and resume refuses replay" do
    fixture = fixture!()

    assert_raise RuntimeError, ~r/crashed after durable intent/, fn ->
      run!(fixture, CrashRuntime)
    end

    assert_raise ArgumentError, ~r/ambiguous outcomes/, fn -> run!(fixture, GoodRuntime) end
  end

  test "malformed output commits terminal errors and does not replay" do
    fixture = fixture!()
    result = run!(fixture, MalformedRuntime)
    assert Enum.all?(result.artifact["rows"], &(&1["status"] == "error"))
    resumed = run!(fixture, CrashRuntime)
    assert Enum.all?(resumed.artifact["rows"], &(&1["status"] == "error"))
  end

  test "exact request boundary rejects a row reporting more calls than remain" do
    fixture = fixture!(request_limit: 1)
    result = run!(fixture, OverBudgetRuntime)
    assert Enum.all?(result.artifact["rows"], &(&1["status"] == "error"))

    assert Enum.any?(
             result.artifact["rows"],
             &String.contains?(&1["error"], "campaign_budget_exhausted")
           )

    assert Enum.all?(result.artifact["rows"], fn row ->
             row["usage"]["requests"] == 2 and row["usage"]["input_tokens"] == 1 and
               row["usage"]["output_tokens"] == 1
           end)

    resumed = run!(fixture, CrashRuntime)
    assert Enum.all?(resumed.artifact["rows"], &(&1["usage"]["requests"] == 2))
  end

  test "checkpoint payload tamper is rejected" do
    root = tmp_dir("checkpoint")
    path = Path.join(root, "checkpoint.json")
    {:ok, pid} = RLMCheckpoint.start_link(path: path, identity: %{"id" => "x"})
    GenServer.stop(pid)
    envelope = path |> File.read!() |> Jason.decode!()
    tampered = put_in(envelope, ["payload", "committed", "x"], %{"key" => "x"})
    File.write!(path, Jason.encode!(tampered))
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             RLMCheckpoint.start_link(path: path, identity: %{"id" => "x"})

    assert message =~ "checksum mismatch"
  after
    Process.flag(:trap_exit, false)
  end

  test "false T3 flags and partial family evidence fail the mechanical gate" do
    artifact = %{
      "evidence_tier" => "t3_paper_scale",
      "manifest" => %{
        "authorities" => %{
          "paper" => %{"arxiv" => "2512.24601v3"},
          "rlm" => %{"commit" => "72d6940142ddfb84ee6be573dc999a37e633e671"},
          "dspy" => %{"version" => "3.3.0b1"}
        },
        "models" => %{"root" => %{}, "submodel" => %{}, "compaction" => %{}},
        "deviations" => []
      },
      "datasets" => %{"s_niah" => %{"logical_instances" => 50, "evaluated_rows" => 50}},
      "execution" => %{"runtime_selection" => "both"},
      "rows" => [],
      "summary" => %{"paper_protocol_complete" => true}
    }

    gate = RLMProtocol.evaluate(artifact)
    refute gate["paper_protocol_complete"]
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_protocol"))["passing"]
  end

  test "a hand-selected matrix without coding-agent model blocks fails exact protocol" do
    protocol = %{
      "reference_runtime" => "alexzhang13_rlm",
      "reference_commit" => "72d6940142ddfb84ee6be573dc999a37e633e671",
      "model_method_matrix" => %{
        "gpt_5" =>
          ~w(base_model codeact_bm25 codeact_subcalls compaction_agent rlm_depth_0 rlm_depth_1 rlm_depth_2 rlm_depth_3)
      },
      "dataset_selection" => %{
        "browsecomp_plus" => "operator_sample_paper_ids_unpublished"
      },
      "compaction" => "iterative_threshold_agent",
      "max_llm_calls_scope" => "subcalls_only",
      "provider_call_accounting" => "root_and_subcalls",
      "cache" => false,
      "reasoning_profiles" => %{
        "gpt_5" => "medium",
        "qwen3_coder_480b_a35b" => "paper_qwen_sampling",
        "claude_opus_4_1" => "claude_code_v2.0.0_default"
      },
      "runtime_matrix" => ~w(dsex standalone_rlm)
    }

    gate = RLMProtocol.evaluate(%{"manifest" => %{"paper_protocol" => protocol}})
    refute Enum.find(gate["checks"], &(&1["id"] == "exact_paper_manifest"))["passing"]
  end

  test "paired bootstrap aggregation is deterministic" do
    rows =
      for approach <- ~w(direct rlm),
          id <- ~w(a b c),
          do: %{
            "runtime" => "dsex",
            "approach" => approach,
            "family" => "s_niah",
            "example_id" => id,
            "query_id" => id,
            "context_size" => nil,
            "metric" => "exact_match",
            "status" => "ok",
            "score" => if(approach == "rlm", do: 1.0, else: 0.0),
            "latency_ms" => 1.0,
            "usage" => %{"requests" => 1, "input_tokens" => 1, "output_tokens" => 1, "usd" => 0.1}
          }

    manifest = %{"execution" => %{"bootstrap_samples" => 100, "confidence" => 0.95, "seed" => 17}}
    assert RLMStatistics.aggregate(rows, manifest) == RLMStatistics.aggregate(rows, manifest)
  end

  test "OOLONG-Pairs uses canonical pair-set F1 rather than token overlap" do
    assert RLMCampaign.score("(b, a)\n(c, d)\n(a, b)", "(a, b)\n(c, x)", "set_f1") == 0.5
    assert RLMCampaign.score("no pairs", "no pairs", "set_f1") == 1.0
  end

  test "official scorer contracts do not fall back to generic exact match" do
    assert_in_delta RLMCampaign.score("12", "10", "oolong_official"), 0.5625, 1.0e-12
    assert RLMCampaign.score("['entity']", "['entity']", "oolong_official") == 1.0
    assert RLMCampaign.score("11-ish", "10", "oolong_official") == 0.0

    assert_raise ArgumentError, ~r/pinned official LLM judge and trec_eval/, fn ->
      RLMCampaign.score("answer", "answer", "official_llm_judge")
    end
  end

  test "OOLONG-Pairs bootstrap clusters context sizes by logical query" do
    rows =
      for approach <- ~w(base rlm), query <- ~w(q1 q2), size <- [1024, 2048] do
        %{
          "runtime" => "dsex",
          "approach" => approach,
          "family" => "oolong_pairs",
          "example_id" => "#{query}@#{size}",
          "query_id" => query,
          "context_size" => size,
          "metric" => "set_f1",
          "status" => "ok",
          "score" => if(approach == "rlm", do: 1.0, else: 0.0),
          "latency_ms" => 1.0,
          "usage" => %{"requests" => 1, "input_tokens" => 1, "output_tokens" => 1, "usd" => 0.0}
        }
      end

    manifest = %{"execution" => %{"bootstrap_samples" => 20, "confidence" => 0.95, "seed" => 17}}
    [comparison] = RLMStatistics.aggregate(rows, manifest)["comparisons"]
    assert comparison["paired_rows"] == 4
    assert comparison["bootstrap_clusters"] == 2
    assert comparison["family"] == "oolong_pairs"
  end

  test "forged duplicate zero-usage rows fail exact key and row evidence checks" do
    datasets =
      Map.new(
        %{
          "s_niah" => {50, nil, nil},
          "browsecomp_plus" => {150, nil, 1000},
          "oolong" => {50, "trec_coarse", nil},
          "oolong_pairs" => {220, "trec_coarse", nil},
          "longbench_v2_codeqa" => {50, nil, nil}
        },
        fn {family, {count, split, docs}} ->
          keys =
            for index <- 1..count,
                do: %{
                  "example_id" => "#{family}-#{index}",
                  "query_id" => "q-#{index}",
                  "context_size" => nil
                }

          {family,
           %{
             "logical_instances" => if(family == "oolong_pairs", do: 20, else: count),
             "evaluated_rows" => count,
             "split" => split,
             "docs_per_instance" => docs,
             "context_grid" =>
               if(family == "oolong_pairs",
                 do: Enum.map(10..20, &round(:math.pow(2, &1))),
                 else: nil
               ),
             "sha256" => String.duplicate("a", 64),
             "sample_ids_sha256" => String.duplicate("b", 64),
             "evaluated_keys" => keys,
             "evidence_in_dataset" => family == "browsecomp_plus"
           }}
        end
      )

    forged =
      for index <- 1..520 do
        %{
          "key" => "forged-#{index}",
          "example_id" => "s_niah-1",
          "query_id" => "q-1",
          "context_size" => nil,
          "family" => "s_niah",
          "model_family" => "gpt_5",
          "approach" => "direct",
          "runtime" => "dsex",
          "status" => "ok",
          "answer" => "x",
          "score" => 1.0,
          "latency_ms" => 1.0,
          "usage" => %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0},
          "metric" => "exact_match",
          "scorer_evidence" => %{},
          "trace_shape" => ["forged"],
          "trace" => [],
          "call_semantics" => %{"provider_calls" => 0},
          "provenance" => %{},
          "error" => nil
        }
      end

    gate =
      RLMProtocol.evaluate(%{
        "evidence_tier" => "t3_paper_scale",
        "datasets" => datasets,
        "rows" => forged,
        "official_scorers" => %{
          "browsecomp_plus" => %{
            "answer" => "pinned_official_llm_judge",
            "retrieval" => "trec_eval_evidence_and_gold_qrels",
            "judge_model" => "forged-judge",
            "prompt_sha256" => String.duplicate("c", 64)
          },
          "oolong" => %{"contract" => "numeric_0.75_abs_error_else_exact"},
          "oolong_pairs" => %{"contract" => "normalized_unordered_pair_set_f1"}
        }
      })

    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_key_sets"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "row_outcomes"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "official_scorers"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_authority"))["passing"]
  end

  defp run!(fixture, runtime) do
    RLMCampaign.run(fixture.manifest_path,
      out: fixture.out,
      checkpoint_dir: fixture.checkpoints,
      runtime: "dsex",
      runtime_modules: %{"dsex" => runtime}
    )
  end

  defp fixture!(opts \\ []) do
    root = tmp_dir("campaign")
    source = Path.join(root, "authority.py")
    File.write!(source, "# pinned\n")

    rows =
      Map.new(dataset_rows(), fn {family, row} ->
        split = if(family in ~w(oolong oolong_pairs), do: "trec_coarse", else: "test")

        {family,
         Map.merge(row, %{
           "source" => "test source",
           "revision" => "test revision",
           "split" => split
         })}
      end)

    dataset_paths =
      Map.new(rows, fn {family, row} ->
        path = Path.join(root, "#{family}.jsonl")
        File.write!(path, Jason.encode!(row) <> "\n")
        {family, path}
      end)

    manifest = manifest(root, source, dataset_paths, Keyword.get(opts, :request_limit, 100))
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    %{
      manifest_path: manifest_path,
      dataset_paths: dataset_paths,
      out: Path.join(root, "out"),
      checkpoints: Path.join(root, "checkpoints")
    }
  end

  defp manifest(_root, source, paths, request_limit) do
    datasets =
      Map.new(paths, fn {family, path} ->
        spec = %{
          "path" => path,
          "sha256" => sha(path),
          "source" => "test source",
          "revision" => "test revision",
          "split" => if(family in ~w(oolong oolong_pairs), do: "trec_coarse", else: "test"),
          "sample_count" => 1,
          "sample_seed" => 17,
          "sample_ids" => ["#{family}-1"],
          "context_grid" => if(family == "oolong_pairs", do: [1024], else: []),
          "docs_per_instance" => if(family == "browsecomp_plus", do: 2, else: nil),
          "metric" => "exact_match"
        }

        {family, spec}
      end)

    pricing = %{"input_per_million" => 1.0, "output_per_million" => 1.0}

    approaches =
      Map.new(~w(direct simple_retrieval compaction rlm), fn approach ->
        settings =
          case approach do
            "direct" ->
              %{"reservation_pricing" => pricing}

            "simple_retrieval" ->
              %{
                "k" => 1,
                "retriever" => "deterministic_lexical",
                "reservation_pricing" => pricing
              }

            "compaction" ->
              %{"chunk_chars" => 100, "max_chunks" => 2, "reservation_pricing" => pricing}

            "rlm" ->
              %{
                "max_iterations" => 2,
                "max_llm_calls" => 2,
                "recursion_depth" => 1,
                "reservation_pricing" => pricing
              }
          end

        {approach,
         %{
           "enabled" => true,
           "runtimes" => ["dsex"],
           "budget" => %{
             "requests" => request_limit,
             "input_tokens" => 100_000,
             "output_tokens" => 100_000,
             "usd" => 100.0
           },
           "settings" => settings
         }}
      end)

    model = %{
      "logical" => "test",
      "dsex" => "test:test",
      "dspy" => "test/test",
      "temperature" => 0.0,
      "reasoning" => "none",
      "max_output_tokens" => 10
    }

    %{
      "schema_version" => 1,
      "campaign_id" => "test-campaign",
      "evidence_tier" => "t2_live_sample",
      "authorities" => %{
        "paper" => %{"arxiv" => "2512.24601v3"},
        "rlm" => %{
          "repository" => "https://example.test/rlm",
          "commit" => "72d6940142ddfb84ee6be573dc999a37e633e671"
        },
        "dspy" => %{
          "repository" => "https://example.test/dspy",
          "version" => "3.3.0b1",
          "commit" => "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
        },
        "sources" => %{"authority" => %{"path" => source, "sha256" => sha(source)}}
      },
      "models" => %{"root" => model, "submodel" => model, "compaction" => model},
      "approaches" => approaches,
      "execution" => %{
        "seed" => 17,
        "concurrency" => 2,
        "row_timeout_ms" => 5000,
        "cancellation_grace_ms" => 100,
        "bootstrap_samples" => 100,
        "confidence" => 0.95
      },
      "datasets" => datasets,
      "deviations" => []
    }
  end

  defp dataset_rows do
    %{
      "s_niah" => %{
        "id" => "s_niah-1",
        "context" => "needle yes",
        "question" => "answer?",
        "answer" => "yes"
      },
      "browsecomp_plus" => %{
        "id" => "browsecomp_plus-1",
        "documents" => [%{"id" => "a", "text" => "yes"}, %{"id" => "b", "text" => "no"}],
        "evidence_document_ids" => ["a"],
        "question" => "answer?",
        "answer" => "yes"
      },
      "oolong" => %{
        "id" => "oolong-1",
        "context" => ["yes"],
        "question" => "answer?",
        "answer" => "yes"
      },
      "oolong_pairs" => %{
        "id" => "oolong_pairs-1",
        "contexts" => %{"1024" => "yes"},
        "question" => "answer?",
        "answer" => "yes"
      },
      "longbench_v2_codeqa" => %{
        "id" => "longbench_v2_codeqa-1",
        "context" => "code",
        "question" => "answer?",
        "choices" => ["yes", "no"],
        "answer" => "yes"
      }
    }
  end

  defp sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp tmp_dir(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-rlm-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
