defmodule GepaCampaignTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{GepaCampaign, GepaReplicationContract, HoverBM25}

  test "research task defaults match the pinned upstream GEPA runner" do
    assert Mix.Tasks.Imp.Benchmark.GepaCampaign.research_defaults() == %{
             temperature: 1.0,
             max_tokens: 16_384,
             max_concurrency: 32,
             optimizer_timeout_ms: 300_000,
             max_retries: 0
           }
  end

  defmodule OptimizerConfigCallback do
    @behaviour Imp.Optimizer.GEPA.Callback

    @impl true
    def on_optimization_start(event, owner) do
      send(owner, {:optimizer_config, event.config})
    end
  end

  test "Imp GEPA campaign keeps local HoVer retrieval out of full replication evidence" do
    dataset_root = tmp_dir("gepa-campaign-data")
    upstream_dir = tmp_dir("gepa-campaign-upstream")
    rows_dir = tmp_dir("gepa-campaign-rows")
    final_dir = tmp_dir("gepa-campaign-final")

    write_dataset_root!(dataset_root)
    write_upstream_gepa_results!(upstream_dir, "gpt-41-mini")

    result =
      GepaCampaign.run(
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
            Imp.BenchmarkTruth.GepaReplicationContract.required_families(),
            [0, 1]
          ),
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@abcdef1",
          "imp" => "deepfates/imp@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      )

    assert File.exists?(result.out_path)

    assert %{"git_sha" => "abcdef2", "rows" => rows} =
             File.read!(result.out_path) |> Jason.decode!()

    assert length(rows) == 6

    assert Enum.all?(rows, fn row ->
             is_map(get_in(row, ["results", "imp_gepa"])) and
               get_in(row, ["results", "imp_gepa", "source"]) =~ "Imp GEPA campaign runner" and
               get_in(row, ["results", "imp_gepa", "source"]) =~ "abcdef2" and
               is_map(row["dataset"]) and
               row["dataset"]["scope"] == "full" and
               row["dataset"]["split_counts"] == %{"train" => 2, "dev" => 2, "test" => 2} and
               is_map(row["token_cost"]) and
               row["seed_variance"]["seeds"] == [0, 1]
           end)

    hover = Enum.find(rows, &(&1["family"] == "hoverBench"))
    hotpot = Enum.find(rows, &(&1["family"] == "HotpotQABench"))
    assert get_in(hotpot, ["dataset", "retrieval", "kind"]) == "bm25s_wiki_abstracts_2017"
    assert get_in(hotpot, ["dataset", "retrieval", "verified"]) == true
    assert get_in(hotpot, ["dataset", "retrieval", "implementation"]) == "imp_local_bm25"
    assert get_in(hover, ["dataset", "retrieval", "kind"]) == "bm25s_wiki_abstracts_2017"
    assert get_in(hover, ["dataset", "retrieval", "corpus_checksum"]) =~ "sha256:"
    assert get_in(hover, ["dataset", "retrieval", "index_checksum"]) =~ "sha256:"
    assert get_in(hover, ["dataset", "retrieval", "verified"]) == true
    assert get_in(hover, ["dataset", "retrieval", "implementation"]) == "imp_local_bm25"
    assert get_in(hover, ["results", "imp_gepa", "score"]) == 1.0

    assert get_in(hotpot, ["metadata", "component_feedback", "components"]) == [
             "create_query_hop2",
             "final_answer",
             "summarize1",
             "summarize2"
           ]

    assert get_in(hover, ["metadata", "component_feedback", "components"]) == [
             "create_query_hop2",
             "create_query_hop3",
             "summarize1",
             "summarize2"
           ]

    ifbench = Enum.find(rows, &(&1["family"] == "IFBench"))

    assert get_in(ifbench, ["metadata", "component_feedback", "components"]) == [
             "ensure_correct_response_module",
             "generate_response_module"
           ]

    Mix.Task.reenable("imp.benchmark.gepa_replication")

    assert_raise Mix.Error, ~r/requires --upstream-evidence/, fn ->
      Mix.Tasks.Imp.Benchmark.GepaReplication.run([
        "--from-gepa-artifact",
        upstream_dir,
        "--imp-input",
        result.out_path,
        "--campaign-id",
        "gepa-campaign-test",
        "--artifact-model",
        "gpt-41-mini",
        "--out",
        final_dir
      ])
    end

    assert Path.wildcard(Path.join(final_dir, "gepa-replication-*.json")) == []
  end

  test "Imp GEPA campaign rejects HoVer rows without source-exact retrieval provenance" do
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
                   GepaCampaign.run(
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
                       "imp" => "deepfates/imp@abcdef2",
                       "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
                     },
                     lm: static_gold_lm()
                   )
                 end
  end

  test "Imp GEPA campaign can write resumable partial family rows" do
    dataset_root = tmp_dir("gepa-campaign-partial-data")
    rows_dir = tmp_dir("gepa-campaign-partial-rows")
    write_dataset_root!(dataset_root)

    result =
      GepaCampaign.run(
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
          "imp" => "deepfates/imp@abcdef2",
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
    assert row["evidence_level"] == "research_preflight"
    refute row["metadata"]["budget_complete"]
    assert row["token_cost"]["usd"] == 0.02
    assert row["token_cost"]["input_tokens"] == 200
    assert Enum.map(row["token_cost"]["breakdown"], & &1["seed"]) == [0, 1]
  end

  test "campaign artifacts and checkpoint identity record requested and effective concurrency" do
    dataset_root = tmp_dir("gepa-campaign-concurrency-identity-data")
    rows_dir = tmp_dir("gepa-campaign-concurrency-identity-rows")
    write_dataset_root!(dataset_root)

    result =
      Imp.context([async_max_workers: 8], fn ->
        GepaCampaign.run(
          campaign_opts(dataset_root, rows_dir,
            campaign_id: "gepa-campaign-concurrency-identity",
            max_concurrency: 32
          )
        )
      end)

    assert get_in(result.report, ["summary", "max_concurrency_requested"]) == 32
    assert get_in(result.report, ["summary", "max_concurrency_effective"]) == 8

    assert get_in(result.report, ["rows", Access.at(0), "metadata", "max_concurrency_requested"]) ==
             32

    assert get_in(result.report, ["rows", Access.at(0), "metadata", "max_concurrency_effective"]) ==
             8

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    assert checkpoint["identity"]["max_concurrency_requested"] == 32
    assert checkpoint["identity"]["max_concurrency_effective"] == 8
  end

  test "Imp GEPA campaign rejects one fallback cost tuple for multiple seeds" do
    dataset_root = tmp_dir("gepa-campaign-ambiguous-cost-data")
    rows_dir = tmp_dir("gepa-campaign-ambiguous-cost-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        seeds: [0, 1],
        token_cost: %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50}
      )

    assert_raise ArgumentError, ~r/require token_cost keyed by family and seed/, fn ->
      GepaCampaign.run(opts)
    end
  end

  test "Imp GEPA campaign rejects invalid source identities before filesystem or LM work" do
    root = tmp_dir("gepa-campaign-invalid-source")
    dataset_root = Path.join(root, "missing-dataset")
    rows_dir = Path.join(root, "rows")
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, opts ->
        Agent.update(calls, &(&1 + 1))
        static_gold_handler(messages, opts)
      end)

    assert_raise ArgumentError,
                 ~r/source_commits must contain concrete dspy, imp, and gepa_artifact identities/,
                 fn ->
                   GepaCampaign.run(
                     dataset_root: dataset_root,
                     campaign_id: "gepa-campaign-invalid-source-test",
                     model: "openai:gpt-4.1-mini-2025-04-14",
                     reflection_model: "openai:gpt-4.1-mini-2025-04-14",
                     out_dir: rows_dir,
                     pricing_source: "test provider usage export",
                     source_commits: %{
                       "dspy" => "unknown",
                       "imp" => "deepfates/imp@abcdef2",
                       "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
                     },
                     lm: lm
                   )
                 end

    assert Agent.get(calls, & &1) == 0
    refute File.exists?(rows_dir)
  end

  test "Imp GEPA campaign rejects unknown partial family names" do
    dataset_root = tmp_dir("gepa-campaign-unknown-family")
    rows_dir = tmp_dir("gepa-campaign-unknown-family-rows")
    write_dataset_root!(dataset_root)

    assert_raise ArgumentError, ~r/unknown Imp GEPA campaign families: MissingBench/, fn ->
      GepaCampaign.run(
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
          "imp" => "deepfates/imp@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      )
    end
  end

  test "Imp GEPA campaign resumes completed seeds without calling the LM again" do
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

    first = GepaCampaign.run(opts)
    first_calls = Agent.get(calls, & &1)
    assert first_calls > 0

    second = GepaCampaign.run(opts)
    assert Agent.get(calls, & &1) == first_calls
    assert first.report["rows"] == second.report["rows"]
    assert_received %{event: :seed_resumed, family: "AIMEBench", seed: 0}
    assert_received %{event: :seed_resumed, family: "AIMEBench", seed: 1}

    [checkpoint] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    assert %{"completed" => completed} = checkpoint |> File.read!() |> Jason.decode!()
    assert Enum.map(completed, & &1["seed"]) == [0, 1]
  end

  test "Imp GEPA campaign checkpoints and resumes individual baseline splits" do
    dataset_root = tmp_dir("gepa-campaign-split-resume-data")
    rows_dir = tmp_dir("gepa-campaign-split-resume-rows")
    write_dataset_root!(dataset_root)
    events = self()

    base_opts =
      campaign_opts(dataset_root, rows_dir, campaign_id: "gepa-campaign-split-resume-test")

    GepaCampaign.run(base_opts)
    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    [completed] = checkpoint["completed"]

    partial = %{
      "baseline" => %{"train" => get_in(completed, ["result", "baseline_train"])},
      "usage" => %{"usd" => 0.0, "input_tokens" => 0, "output_tokens" => 0}
    }

    checkpoint =
      checkpoint
      |> Map.put("completed", [])
      |> Map.put("in_progress", %{"0" => partial})

    File.write!(checkpoint_path, Jason.encode!(checkpoint))
    GepaCampaign.run(Keyword.put(base_opts, :reporter, &send(events, &1)))

    refute_received %{event: :seed_checkpoint, baseline_prefixes: %{"train" => 1}}

    assert_received %{
      event: :seed_checkpoint,
      phase: :baseline,
      baseline_splits: ["dev", "train"]
    }

    assert_received %{
      event: :seed_checkpoint,
      phase: :baseline,
      baseline_splits: ["dev", "test", "train"]
    }
  end

  test "Imp GEPA campaign resumes a committed baseline row prefix without replay or usage loss" do
    dataset_root = tmp_dir("gepa-campaign-row-prefix-data")
    rows_dir = tmp_dir("gepa-campaign-row-prefix-rows")
    write_dataset_root!(dataset_root)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    receiver = self()

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, handler_opts ->
        Agent.update(calls, &(&1 + 1))

        :telemetry.execute(
          [:req_llm, :token_usage],
          %{total_cost: 0.001, tokens: %{input_tokens: 10, output_tokens: 5}},
          %{}
        )

        static_gold_handler(messages, handler_opts)
      end)

    reporter = fn
      %{
        phase: :baseline,
        baseline_prefixes: %{"train" => 1},
        baseline_in_flight: []
      } ->
        [path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
        send(receiver, {:committed_row_checkpoint, path |> File.read!() |> Jason.decode!()})

      _event ->
        :ok
    end

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-row-prefix",
        lm: lm,
        reporter: reporter
      )

    first = GepaCampaign.run(opts)
    assert_receive {:committed_row_checkpoint, committed_checkpoint}

    assert %{
             "in_progress" => %{
               "0" => %{
                 "baseline" => %{
                   "train" => %{
                     "schema_version" => 1,
                     "row_count" => 2,
                     "committed_count" => 1,
                     "score_sum" => 1.0
                   }
                 },
                 "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
               }
             }
           } = committed_checkpoint

    refute Map.has_key?(
             get_in(committed_checkpoint, ["in_progress", "0", "baseline", "train"]),
             "dispatch_intent"
           )

    full_calls = Agent.get(calls, & &1)
    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    File.write!(checkpoint_path, Jason.encode!(committed_checkpoint, pretty: true))
    Agent.update(calls, fn _count -> 0 end)

    resumed = GepaCampaign.run(Keyword.delete(opts, :reporter))

    assert Agent.get(calls, & &1) == full_calls - 1

    assert get_in(resumed.report, ["rows", Access.at(0), "results"]) ==
             get_in(first.report, ["rows", Access.at(0), "results"])

    assert get_in(resumed.report, ["rows", Access.at(0), "train_dev_test_gap"]) ==
             get_in(first.report, ["rows", Access.at(0), "train_dev_test_gap"])

    first_cost = get_in(first.report, ["rows", Access.at(0), "token_cost"])
    resumed_cost = get_in(resumed.report, ["rows", Access.at(0), "token_cost"])
    assert resumed_cost["input_tokens"] == first_cost["input_tokens"]
    assert resumed_cost["output_tokens"] == first_cost["output_tokens"]
    assert_in_delta resumed_cost["usd"], first_cost["usd"], 1.0e-12
  end

  test "Imp GEPA campaign refuses to replay an ambiguously dispatched baseline row" do
    dataset_root = tmp_dir("gepa-campaign-ambiguous-row-data")
    rows_dir = tmp_dir("gepa-campaign-ambiguous-row-rows")
    write_dataset_root!(dataset_root)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    receiver = self()

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, handler_opts ->
        call_index = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

        if call_index == 0 do
          [path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
          send(receiver, {:ambiguous_row_checkpoint, path |> File.read!() |> Jason.decode!()})
        end

        static_gold_handler(messages, handler_opts)
      end)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-ambiguous-row",
        lm: lm,
        max_concurrency: 2
      )

    GepaCampaign.run(opts)
    assert_receive {:ambiguous_row_checkpoint, ambiguous_checkpoint}

    assert get_in(ambiguous_checkpoint, ["in_progress", "0", "baseline", "train"]) == %{
             "schema_version" => 1,
             "row_count" => 2,
             "committed_count" => 0,
             "score_sum" => 0.0,
             "dispatch_intent" => %{"start" => 0, "count" => 2}
           }

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    File.write!(checkpoint_path, Jason.encode!(ambiguous_checkpoint, pretty: true))
    Agent.update(calls, fn _count -> 0 end)

    assert_raise ArgumentError,
                 ~r/durable dispatch intent for train rows 0\.\.1 has an ambiguous outcome; requests may have been sent or completed, so replay is refused/,
                 fn -> GepaCampaign.run(opts) end

    assert Agent.get(calls, & &1) == 0
  end

  test "baseline prefix checkpoints preserve configured evaluation concurrency" do
    dataset_root = tmp_dir("gepa-campaign-prefix-concurrency-data")
    rows_dir = tmp_dir("gepa-campaign-prefix-concurrency-rows")
    write_dataset_root!(dataset_root)
    {:ok, concurrency} = Agent.start_link(fn -> %{active: 0, maximum: 0} end)
    receiver = self()

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn messages, handler_opts ->
        maximum =
          Agent.get_and_update(concurrency, fn state ->
            active = state.active + 1
            maximum = max(state.maximum, active)
            {maximum, %{active: active, maximum: maximum}}
          end)

        if maximum == 2, do: send(receiver, :baseline_calls_concurrent)
        Process.sleep(25)
        response = static_gold_handler(messages, handler_opts)
        Agent.update(concurrency, &%{&1 | active: &1.active - 1})
        response
      end)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-prefix-concurrency",
        lm: lm,
        max_concurrency: 2
      )

    GepaCampaign.run(opts)

    assert_received :baseline_calls_concurrent
    assert Agent.get(concurrency, & &1.maximum) == 2
  end

  test "campaign evaluation timeout bounds baseline and final scoring calls" do
    dataset_root = tmp_dir("gepa-campaign-evaluation-timeout-data")
    rows_dir = tmp_dir("gepa-campaign-evaluation-timeout-rows")
    write_dataset_root!(dataset_root)
    receiver = self()

    lm =
      static_gold_lm()
      |> put_in([:opts, :handler], fn _messages, _handler_opts ->
        send(receiver, :slow_evaluation_started)
        Process.sleep(:infinity)
      end)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-evaluation-timeout",
        lm: lm,
        max_concurrency: 2,
        execution: %{
          "source" => "test",
          "lm" => %{"optimizer_timeout_ms" => 25}
        }
      )

    task = Task.async(fn -> GepaCampaign.run(opts) end)

    # `:slow_evaluation_started` is an explicit start signal the stub sends before
    # it sleeps, so this waits for the campaign to actually reach evaluation. The
    # window only bounds campaign startup latency (dataset load, generation), which
    # can exceed 1s on a loaded CI runner — 10s is a CI-safe ceiling that still
    # fails loudly if evaluation never starts. Ticket dee-m1de.
    assert_receive :slow_evaluation_started, 10_000
    assert %{report: %{"rows" => [_row]}} = Task.await(task, 10_000)
  end

  test "Imp GEPA campaign rejects artifact optimizer state at the program resume boundary" do
    dataset_root = tmp_dir("gepa-campaign-generation-resume-data")
    rows_dir = tmp_dir("gepa-campaign-generation-resume-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-generation-resume",
        generations: 2
      )

    GepaCampaign.run(opts)

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    [completed] = checkpoint["completed"]

    [spec | _] =
      dataset_root
      |> Path.join("families.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("families")

    receiver = self()

    Imp.Optimize.Anything.run(
      spec["instructions"],
      fn _candidate, _example -> 1.0 end,
      dataset: [:dev_one, :dev_two],
      config:
        Imp.Optimize.Anything.Config.new(
          engine: [max_candidate_proposals: 1, parallel: false],
          reflection: [
            custom_candidate_proposer: fn _candidate, _component, _records, _iteration ->
              "checkpointed mutation"
            end
          ]
        ),
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

    assert Enum.map(candidates, & &1["id"]) == [0]
    assert interrupted["completed"] == []

    assert_raise ArgumentError, ~r/GEPA resume state does not match the seed candidate/, fn ->
      GepaCampaign.run(opts)
    end
  end

  test "Imp GEPA campaign rejects checkpoint configuration and dataset mismatches" do
    dataset_root = tmp_dir("gepa-campaign-checkpoint-identity-data")
    rows_dir = tmp_dir("gepa-campaign-checkpoint-identity-rows")
    write_dataset_root!(dataset_root)

    opts = campaign_opts(dataset_root, rows_dir, campaign_id: "gepa-checkpoint-identity")
    GepaCampaign.run(opts)

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      GepaCampaign.run(Keyword.put(opts, :generations, 2))
    end

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      GepaCampaign.run(Keyword.put(opts, :execution, %{"lm" => %{"max_tokens" => 512}}))
    end

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    [entry] = checkpoint["completed"]

    malformed =
      checkpoint
      |> Map.put("completed", [entry, entry])

    File.write!(checkpoint_path, Jason.encode!(malformed))

    assert_raise ArgumentError, ~r/duplicate seed entries in GEPA checkpoint/, fn ->
      GepaCampaign.run(opts)
    end

    missing_feedback =
      update_in(checkpoint, ["completed", Access.at(0), "result"], fn result ->
        Map.delete(result, "component_feedback")
      end)

    File.write!(checkpoint_path, Jason.encode!(missing_feedback))

    assert_raise ArgumentError, ~r/invalid seed entry in GEPA checkpoint/, fn ->
      GepaCampaign.run(opts)
    end

    File.write!(checkpoint_path, Jason.encode!(checkpoint))

    File.write!(
      Path.join([dataset_root, "AIMEBench", "train.jsonl"]),
      Jason.encode!(%{problem: "changed", answer: "42"}) <> "\n"
    )

    assert_raise ArgumentError, ~r/checkpoint configuration or dataset identity mismatch/, fn ->
      GepaCampaign.run(opts)
    end
  end

  test "requested seeds and the family metric budget reach distinct optimizer configs" do
    dataset_root = tmp_dir("gepa-campaign-optimizer-config-data")
    rows_dir = tmp_dir("gepa-campaign-optimizer-config-rows")
    write_dataset_root!(dataset_root)
    set_family_budget!(dataset_root, "AIMEBench", 4)

    result =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-optimizer-config",
        seeds: [17, 29],
        token_cost: explicit_costs(["AIMEBench"], [17, 29]),
        optimizer_callbacks: [{OptimizerConfigCallback, self()}]
      )
      |> GepaCampaign.run()

    assert_receive {:optimizer_config, %{seed: 17, max_metric_calls: 4}}
    assert_receive {:optimizer_config, %{seed: 29, max_metric_calls: 4}}

    [row] = result.report["rows"]
    evidence = row["metric_call_evidence"]

    assert evidence["basis"] == "observed_and_enforced"
    assert evidence["enforced_limits"] == %{"imp_gepa" => true}

    assert Enum.map(evidence["per_seed"], &{&1["seed"], &1["observed"], &1["limit"]}) ==
             [{17, 4, 4}, {29, 4, 4}]
  end

  test "reflection LM is used for optimizer proposals and Papillon names its actual judge" do
    dataset_root = tmp_dir("gepa-campaign-reflection-data")
    rows_dir = tmp_dir("gepa-campaign-reflection-rows")
    write_dataset_root!(dataset_root)
    receiver = self()

    reflection_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(receiver, {:reflection_call, messages})

          %{
            __imp_lm_output__: %{"instruction" => "Use the reflected instruction."},
            __imp_lm_metadata__: %{provider: "test"}
          }
        end
      ]
    }

    result =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-reflection",
        families: ["Papillon"],
        reflection_lm: reflection_lm
      )
      |> GepaCampaign.run()

    assert_receive {:reflection_call, messages}
    assert Enum.any?(messages, &(Map.get(&1, :content, "") =~ "Improve exactly one"))

    [row] = result.report["rows"]
    assert row["metric_judge"]["model"] == "openai:gpt-4.1-mini-2025-04-14"
    refute row["metric_judge"]["model"] == row["reflection_model"]
  end

  test "semantic proposal failures abort boundedly and remain durable in the checkpoint" do
    dataset_root = tmp_dir("gepa-campaign-semantic-stop-data")
    rows_dir = tmp_dir("gepa-campaign-semantic-stop-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-semantic-stop",
        generations: 5,
        reflection_lm: fn _messages, _opts -> {:error, :malformed_provider_output} end,
        execution: %{
          "semantic_progress" => %{"max_consecutive_proposal_errors" => 2}
        }
      )

    error = assert_raise ArgumentError, fn -> GepaCampaign.run(opts) end
    assert error.message =~ "semantic_progress_exhausted"
    assert error.message =~ "proposal_error"

    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()
    optimizer_state = get_in(checkpoint, ["in_progress", "0", "optimizer_state"])

    assert optimizer_state["iteration"] == 2

    assert get_in(optimizer_state, ["stop_reason", "items", Access.at(0), "value"]) ==
             "stopper"

    assert Path.wildcard(Path.join(rows_dir, "imp-gepa-rows-*.json")) == []
  end

  test "resumed seed selection uses dev even when another seed has the higher test score" do
    dataset_root = tmp_dir("gepa-campaign-dev-selection-data")
    rows_dir = tmp_dir("gepa-campaign-dev-selection-rows")
    write_dataset_root!(dataset_root)

    opts =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-dev-selection",
        seeds: [10, 20],
        token_cost: explicit_costs(["AIMEBench"], [10, 20])
      )

    GepaCampaign.run(opts)
    [checkpoint_path] = Path.wildcard(Path.join(rows_dir, "gepa-checkpoints/*.json"))

    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

    completed =
      Enum.map(checkpoint["completed"], fn entry ->
        scores =
          case entry["seed"] do
            10 -> %{"dev" => 0.9, "test" => 0.1}
            20 -> %{"dev" => 0.2, "test" => 1.0}
          end

        update_in(entry, ["result"], &Map.merge(&1, scores))
      end)

    File.write!(checkpoint_path, Jason.encode!(%{checkpoint | "completed" => completed}))

    [row] = GepaCampaign.run(opts).report["rows"]

    assert get_in(row, ["results", "imp_gepa", "seed"]) == 10
    assert get_in(row, ["results", "imp_gepa", "score"]) == 0.1
    assert get_in(row, ["seed_selection", "imp_gepa", "selection_split"]) == "dev"
    assert get_in(row, ["seed_selection", "imp_gepa", "test_scores_used"]) == false
  end

  test "Imp evidence satisfies the strict contract once converter comparators are supplied" do
    dataset_root = tmp_dir("gepa-campaign-contract-data")
    rows_dir = tmp_dir("gepa-campaign-contract-rows")
    write_dataset_root!(dataset_root)
    set_family_budget!(dataset_root, "AIMEBench", 4)

    [imp_row] =
      campaign_opts(dataset_root, rows_dir,
        campaign_id: "gepa-campaign-contract",
        seeds: [3, 5],
        generations: :metric_budget,
        token_cost: explicit_costs(["AIMEBench"], [3, 5])
      )
      |> GepaCampaign.run()
      |> get_in([:report, "rows"])

    selection = get_in(imp_row, ["seed_selection", "imp_gepa"])
    assert imp_row["evidence_level"] == "research_campaign"
    assert imp_row["metadata"]["budget_complete"]
    observed_imp = get_in(imp_row, ["metric_call_evidence", "observed", "imp_gepa"])

    rows =
      Enum.map(GepaReplicationContract.required_families(), fn family ->
        dataset =
          if family in ["HotpotQABench", "hoverBench"] do
            put_in(imp_row["dataset"], ["retrieval"], %{
              "verified" => true,
              "implementation" => "upstream_python_bm25s",
              "corpus_checksum" => "sha256:" <> String.duplicate("a", 64),
              "index_checksum" => "sha256:" <> String.duplicate("b", 64)
            })
          else
            imp_row["dataset"]
          end

        imp_row
        |> Map.put("family", family)
        |> Map.put("dataset", dataset)
        |> Map.put("results", contract_results(imp_row))
        |> Map.put("seed_selection", Map.new(contract_optimizers(), &{&1, selection}))
        |> Map.put("metric_call_evidence", %{
          "basis" => "observed_and_enforced",
          "source" => "optimizer runtime exports and enforced campaign limits",
          "observed" =>
            Map.merge(Map.new(contract_optimizers(), &{&1, 1}), %{
              "imp_gepa" => observed_imp
            }),
          "enforced_limits" => Map.new(contract_optimizers(), &{&1, true})
        })
        |> maybe_put_contract_judge(family)
      end)

    assert GepaReplicationContract.validate_rows(rows).passing
  end

  defp static_gold_lm do
    %{
      module: Imp.LM.Static,
      opts: [handler: &static_gold_handler/2]
    }
  end

  defp static_gold_handler(messages, _opts) do
    prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

    [
      {"num_pii_leaked", %{reasoning: "No PII leaked.", num_pii_leaked: 0}},
      {"judgment", %{reasoning: "Response A is good enough.", judgment: true}},
      {"llm_request", %{llm_request: "redacted request", response: "gold"}},
      {"retrieved_docs", %{retrieved_docs: ["gold | supporting document"]}},
      {"[[ ## summary ## ]]", %{reasoning: "Summarized.", summary: "gold evidence"}},
      {"[[ ## query ## ]]", %{reasoning: "Find the gold evidence.", query: "gold"}},
      {"[[ ## answer ## ]]", %{reasoning: "Solved.", answer: "42"}},
      {"response", %{response: "gold"}}
    ]
    |> Enum.find_value(%{reasoning: "Completed.", answer: "42"}, fn {marker, response} ->
      if String.contains?(prompt, marker), do: response
    end)
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
          "imp" => "deepfates/imp@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      ],
      overrides
    )
  end

  defp set_family_budget!(dataset_root, family, budget) do
    path = Path.join(dataset_root, "families.json")
    document = path |> File.read!() |> Jason.decode!()

    families =
      Enum.map(document["families"], fn
        %{"family" => ^family} = spec -> Map.put(spec, "metric_calls", budget)
        spec -> spec
      end)

    File.write!(path, Jason.encode!(%{document | "families" => families}))
  end

  defp contract_optimizers, do: ["baseline", "dspy_gepa", "imp_gepa", "mipro_v2"]

  defp contract_results(imp_row) do
    Map.new(contract_optimizers(), fn
      "imp_gepa" -> {"imp_gepa", get_in(imp_row, ["results", "imp_gepa"])}
      optimizer -> {optimizer, %{"score" => 0.5, "source" => "upstream runtime #{optimizer}"}}
    end)
  end

  defp maybe_put_contract_judge(row, "Papillon") do
    Map.put(row, "metric_judge", %{
      "kind" => "papillon_quality_leakage",
      "model" => "openai:gpt-4.1-mini-2025-04-14",
      "quality_judge" => "pairwise quality judge export",
      "leakage_judge" => "pii leakage judge export"
    })
  end

  defp maybe_put_contract_judge(row, _family), do: row

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
    Jason.encode!(%{
      question: "HotpotQABench #{split} question #{index}",
      answer: "42",
      supporting_facts: %{title: ["gold"], sent_id: [0]},
      context: %{title: ["gold"], sentences: [["supporting document"]]}
    })
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

  defp campaign_contract("HotpotQABench", family_dir) do
    %{
      signature: "question -> answer",
      input_keys: ["question"],
      output_key: "answer",
      upstream_metric: "dspy.evaluate.answer_exact_match",
      retrieval: write_retrieval_fixture!(family_dir)
    }
  end

  defp campaign_contract("hoverBench", family_dir) do
    retrieval = write_retrieval_fixture!(family_dir)

    %{
      signature: "claim -> retrieved_docs",
      input_keys: ["claim"],
      output_key: "retrieved_docs",
      upstream_metric: "hover_utils.discrete_retrieval_eval",
      retrieval: retrieval
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

  defp write_retrieval_fixture!(family_dir) do
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
      "kind" => "bm25s_wiki_abstracts_2017",
      "status" => "present",
      "source_url" => "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
      "corpus_path" => corpus_path,
      "index_path" => index_dir,
      "corpus_checksum" => "sha256:" <> HoverBM25.checksum_path(corpus_path),
      "index_checksum" => "sha256:" <> HoverBM25.checksum_path(index_dir)
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
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
