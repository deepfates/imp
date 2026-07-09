defmodule DashboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "dashboard aggregates lane artifacts and require-full refuses missing lanes" do
    root = tmp_dir("dashboard")
    trace_dir = Path.join(root, "trace")
    overhead_dir = Path.join(root, "overhead")
    optimizer_dir = Path.join(root, "optimizer")
    gepa_dir = Path.join(root, "gepa")
    rag_tool_agent_dir = Path.join(root, "rag-tool-agent")
    rlm_dir = Path.join(root, "rlm-benchmark")
    live_matrix_dir = Path.join(root, "live-matrix")
    results_dir = Path.join(root, "results")
    gate_dir = Path.join(root, "gate-evidence")
    out_dir = Path.join(root, "out")

    Enum.each(
      [
        trace_dir,
        overhead_dir,
        optimizer_dir,
        gepa_dir,
        rag_tool_agent_dir,
        rlm_dir,
        live_matrix_dir,
        results_dir,
        gate_dir,
        out_dir
      ],
      &File.mkdir_p!/1
    )

    write_gate_evidence!(gate_dir, "product_package", "package.check")
    write_gate_evidence!(gate_dir, "livebook_execute", "livebook.execute.check")
    write_gate_evidence!(gate_dir, "protocol_gates", "protocol.check")

    write_json!(Path.join(trace_dir, "golden-trace-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 6,
        "passing" => 6,
        "all_cases_passing" => true,
        "prediction_parity" => true,
        "tool_trace_parity" => true,
        "dsex_semantic_checks" => %{"all_passing" => true, "passing" => 4, "total" => 4}
      }
    })

    write_json!(Path.join(overhead_dir, "overhead-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "max_ratio" => 50.0,
      "summary" => %{"total" => 1, "passing" => 1, "all_passing" => true},
      "cases" => [%{"id" => "adapter_parse", "median_ratio_dsex_over_dspy" => 0.5}]
    })

    write_json!(Path.join(optimizer_dir, "optimizer-lift-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 10,
        "passing" => 10,
        "all_passing" => true,
        "direct_comparisons" => 7,
        "dsex_only_or_deviation" => 3,
        "full_optimizer_parity" => true
      },
      "rows" => [
        %{"optimizer" => "LabeledFewShot", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "BootstrapFewShot", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "RandomSearch", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "COPRO", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "MIPROv2", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "SIMBA", "comparison_status" => "direct", "passing" => true},
        %{"optimizer" => "GEPA", "comparison_status" => "direct", "passing" => true},
        %{
          "optimizer" => "InstructionSearch",
          "comparison_status" => "dsex_only",
          "passing" => true
        },
        %{
          "optimizer" => "BootstrapFinetune",
          "comparison_status" => "intentional_deviation",
          "passing" => true
        },
        %{
          "optimizer" => "GRPO",
          "comparison_status" => "intentional_deviation",
          "passing" => true
        }
      ]
    })

    write_json!(Path.join(gepa_dir, "gepa-replication-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-replication",
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "source" => %{"mode" => "input"},
      "summary" => %{
        "all_passing" => true,
        "full_gepa_replication" => true,
        "evidence_level" => "research_campaign"
      },
      "rows" => gepa_rows()
    })

    write_json!(Path.join(rag_tool_agent_dir, "rag-tool-agent-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 12,
        "passing" => 12,
        "all_passing" => true,
        "direct_comparisons" => 2,
        "dsex_only_or_deviation" => 10,
        "full_rag_tool_agent_parity" => true
      }
    })

    write_json!(Path.join(rlm_dir, "rlm-benchmark-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 6,
        "passing" => 6,
        "all_passing" => true,
        "full_rlm_benchmark_parity" => true,
        "approaches" => %{
          "direct_prompt" => %{"examples" => 2, "accuracy" => 1.0},
          "simple_rag" => %{"examples" => 2, "accuracy" => 1.0},
          "rlm" => %{"examples" => 2, "accuracy" => 1.0}
        },
        "uncertainty" => %{"n" => 6, "accuracy" => 1.0}
      }
    })

    write_json!(Path.join(results_dir, "dsex-dspy-parity-campaign-test-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "provider" => "req_llm",
      "model" => "test-model",
      "coverage" => %{"covered" => 4, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false}
    })

    write_json!(Path.join(live_matrix_dir, "live-matched-model-matrix-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "models" => 1,
        "full_parity_models" => 0,
        "matrix_complete" => false,
        "dsex_instrumentation" => %{
          "models_with_complete_instrumentation" => 1,
          "total_models" => 1,
          "complete" => true,
          "mean_lm_duration_share" => 0.98,
          "dominant_latency_source" => "provider_model"
        },
        "runtime_shape" => %{
          "models_with_runtime_shape" => 1,
          "total_models" => 1,
          "complete" => false,
          "mean_message_chars_ratio_dsex_over_dspy" => 1.05,
          "mean_raw_chars_ratio_dsex_over_dspy" => 0.25,
          "by_model" => %{
            "gpt-test-mini" => %{
              "complete" => false,
              "coverage" => %{
                "complete" => false,
                "message_chars_comparable_rows" => 2,
                "raw_chars_comparable_rows" => 4,
                "total_rows" => 4
              },
              "by_task" => %{
                "hotpotqa" => %{
                  "complete" => false,
                  "coverage" => %{
                    "complete" => false,
                    "message_chars_comparable_rows" => 0,
                    "raw_chars_comparable_rows" => 2,
                    "total_rows" => 2
                  }
                }
              }
            }
          }
        },
        "disagreements" => %{
          "count" => 3,
          "pass_disagreements" => 2,
          "answer_disagreements" => 3,
          "directions" => %{"dsex_only_pass" => 1, "dspy_only_pass" => 1, "both_fail" => 1}
        },
        "prompt_contract" => %{
          "models_with_current_prompt_contract" => 0,
          "total_models" => 1,
          "complete" => false
        },
        "execution" => %{
          "models_with_consistent_max_concurrency" => 0,
          "total_models" => 1,
          "complete" => false,
          "by_model" => %{
            "gpt-test-mini" => %{
              "max_concurrency_consistent" => false,
              "max_concurrency" => nil,
              "max_concurrency_values" => [4, 8]
            }
          }
        },
        "latency" => %{
          "complete" => false,
          "failing_models" => ["gpt-test-mini"],
          "by_model" => %{
            "gpt-test-mini" => %{
              "latency_parity" => false,
              "ratio_dsex_over_dspy" => 1.62,
              "transport" => %{"req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}}
            }
          }
        },
        "transport" => %{
          "recorded_models" => 1,
          "total_models" => 1,
          "by_model" => %{
            "gpt-test-mini" => %{
              "req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}
            }
          }
        },
        "required_lanes" => %{
          "current_low_cost" => %{
            "present" => true,
            "full_evidence" => false,
            "models" => ["gpt-test-mini"],
            "best_status" => "smoke",
            "coverage" => %{
              "covered_rows" => 4,
              "expected_rows" => 8724,
              "remaining_rows" => 8720,
              "coverage_percent" => 0.0459,
              "full" => false
            },
            "cost" => %{
              "estimated_remaining_total_tokens" => 28_392_320,
              "estimated_full_total_tokens" => 28_405_344,
              "status" => "token_estimate"
            }
          },
          "frontier_sanity" => %{
            "present" => false,
            "full_evidence" => false,
            "models" => [],
            "best_status" => "missing"
          },
          "historical_research" => %{
            "present" => false,
            "full_evidence" => false,
            "models" => [],
            "best_status" => "missing"
          }
        }
      },
      "models" => [
        %{
          "model" => "gpt-test-mini",
          "lane_tags" => ["current_low_cost"],
          "parity" => %{"latency_parity" => false},
          "latency" => %{"latency_ratio_dsex_over_dspy" => 1.62},
          "execution" => %{
            "max_concurrency_consistent" => false,
            "max_concurrency" => nil,
            "max_concurrency_values" => [4, 8]
          },
          "proof" => %{
            "max_concurrency_consistent" => false,
            "max_concurrency" => nil,
            "max_concurrency_values" => [4, 8]
          },
          "transport" => %{"req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}},
          "artifact" => %{"path" => "benchmarks/results/gpt-test-mini.json"}
        }
      ]
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--trace-dir",
        trace_dir,
        "--overhead-dir",
        overhead_dir,
        "--optimizer-dir",
        optimizer_dir,
        "--gepa-dir",
        gepa_dir,
        "--rag-tool-agent-dir",
        rag_tool_agent_dir,
        "--rlm-dir",
        rlm_dir,
        "--live-matrix-dir",
        live_matrix_dir,
        "--results-dir",
        results_dir,
        "--gate-dir",
        gate_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()

    refute dashboard["full_parity"]
    assert dashboard["performance_claim_supported"]
    refute dashboard["release_gate"]["passing"]

    assert dashboard["release_gate"]["blocking_lanes"] == [
             "live_provider_smoke",
             "live_matched_model",
             "public_claims"
           ]

    assert Enum.count(dashboard["release_gate"]["checks"]) == 12
    assert dashboard["claims"]["status"] == "failing"
    assert dashboard["claims"]["summary"]["total"] == 10
    assert dashboard["claims"]["summary"]["proven"] == 8
    assert dashboard["claims"]["summary"]["blocked"] == 2

    proven_claim_ids =
      dashboard["claims"]["claims"]
      |> Enum.filter(&(&1["status"] == "proven"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert proven_claim_ids == [
             "claim.dspy_semantics.golden_trace",
             "claim.gepa_replication.full",
             "claim.optimizer_lift.full",
             "claim.performance.provider_free",
             "claim.product.public_api_installable",
             "claim.protocols.production_boundaries",
             "claim.rag_tools_agents.full",
             "claim.rlm.provider_free_benchmark"
           ]

    assert dashboard["lanes"]["product_package"]["status"] == "full"
    assert dashboard["lanes"]["livebook_execute"]["status"] == "full"
    assert dashboard["lanes"]["protocol_gates"]["status"] == "full"
    assert dashboard["lanes"]["live_provider_smoke"]["status"] == "missing"

    assert Enum.map(
             dashboard["claims"]["blocking_requirements"],
             &{&1["claim_id"], &1["missing_requirements"]}
           ) == [
             {"claim.docs.livebooks_real_provider", ["live.provider.smoke"]},
             {"claim.live_matched_model.full_parity", ["live_matched_model.full"]}
           ]

    assert dashboard["lanes"]["golden_trace"]["status"] == "full"
    assert dashboard["lanes"]["rlm_benchmark"]["status"] == "full"
    assert dashboard["lanes"]["provider_free_overhead"]["status"] == "full"
    assert dashboard["lanes"]["live_matched_model"]["status"] == "failing"
    assert dashboard["lanes"]["live_matched_model"]["summary"]["matrix_complete"] == false
    live_blockers = dashboard["lanes"]["live_matched_model"]["summary"]["blocking_requirements"]

    assert Enum.map(live_blockers, & &1["kind"]) == [
             "live_lane_full_evidence",
             "live_lane_missing",
             "live_lane_missing",
             "live_latency_parity_false",
             "live_max_concurrency_inconsistent",
             "runtime_shape_incomplete"
           ]

    assert Enum.map(live_blockers, & &1["lane"]) == [
             "current_low_cost",
             "frontier_sanity",
             "historical_research",
             nil,
             nil,
             nil
           ]

    assert [
             %{
               "kind" => "live_lane_full_evidence",
               "lane" => "current_low_cost",
               "models" => ["gpt-test-mini"],
               "status" => "smoke",
               "coverage" => %{"remaining_rows" => 8720},
               "cost" => %{"estimated_remaining_total_tokens" => 28_392_320}
             },
             %{"kind" => "live_lane_missing", "lane" => "frontier_sanity"},
             %{"kind" => "live_lane_missing", "lane" => "historical_research"},
             %{
               "kind" => "live_latency_parity_false",
               "models" => ["gpt-test-mini"],
               "failures" => [
                 %{
                   "model" => "gpt-test-mini",
                   "latency" => %{"latency_ratio_dsex_over_dspy" => 1.62},
                   "transport" => %{
                     "req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}
                   }
                 }
               ]
             },
             %{
               "kind" => "live_max_concurrency_inconsistent",
               "failures" => [
                 %{
                   "model" => "gpt-test-mini",
                   "execution" => %{
                     "max_concurrency_consistent" => false,
                     "max_concurrency_values" => [4, 8]
                   },
                   "proof" => %{
                     "max_concurrency_consistent" => false,
                     "max_concurrency_values" => [4, 8]
                   }
                 }
               ]
             },
             %{
               "kind" => "runtime_shape_incomplete",
               "runtime_shape" => %{
                 "by_model" => %{
                   "gpt-test-mini" => %{
                     "by_task" => %{
                       "hotpotqa" => %{
                         "coverage" => %{"message_chars_comparable_rows" => 0}
                       }
                     }
                   }
                 }
               }
             }
           ] = live_blockers

    live_gate_check =
      Enum.find(dashboard["release_gate"]["checks"], &(&1["lane"] == "live_matched_model"))

    assert live_gate_check["blocking_requirements"] == live_blockers

    assert dashboard["lanes"]["live_matched_model"]["summary"]["dsex_instrumentation"][
             "dominant_latency_source"
           ] == "provider_model"

    assert dashboard["lanes"]["live_matched_model"]["summary"]["dsex_instrumentation"][
             "mean_lm_duration_share"
           ] == 0.98

    assert dashboard["lanes"]["live_matched_model"]["summary"]["runtime_shape"][
             "mean_message_chars_ratio_dsex_over_dspy"
           ] == 1.05

    assert dashboard["lanes"]["live_matched_model"]["summary"]["runtime_shape"][
             "mean_raw_chars_ratio_dsex_over_dspy"
           ] == 0.25

    assert dashboard["lanes"]["live_matched_model"]["summary"]["disagreements"][
             "pass_disagreements"
           ] == 2

    assert dashboard["lanes"]["live_matched_model"]["summary"]["disagreements"]["directions"][
             "dsex_only_pass"
           ] == 1

    refute dashboard["lanes"]["live_matched_model"]["summary"]["prompt_contract"]["complete"]

    assert dashboard["lanes"]["optimizer_lift"]["status"] == "full"

    assert dashboard["lanes"]["optimizer_lift"]["summary"]["direct_optimizers"] == [
             "BootstrapFewShot",
             "COPRO",
             "GEPA",
             "LabeledFewShot",
             "MIPROv2",
             "RandomSearch",
             "SIMBA"
           ]

    assert dashboard["lanes"]["optimizer_lift"]["summary"][
             "dsex_only_or_deviation_optimizers"
           ] == [
             "BootstrapFinetune",
             "GRPO",
             "InstructionSearch"
           ]

    assert dashboard["lanes"]["gepa_replication"]["status"] == "full"
    assert dashboard["lanes"]["gepa_replication"]["summary"]["full_gepa_replication"]
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_families"] == []
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_fields"] == []

    assert dashboard["lanes"]["rag_tool_agent"]["status"] == "full"

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Dsex.Benchmark.Dashboard.run([
            "--trace-dir",
            trace_dir,
            "--overhead-dir",
            overhead_dir,
            "--optimizer-dir",
            optimizer_dir,
            "--gepa-dir",
            gepa_dir,
            "--rag-tool-agent-dir",
            rag_tool_agent_dir,
            "--live-matrix-dir",
            live_matrix_dir,
            "--results-dir",
            results_dir,
            "--gate-dir",
            gate_dir,
            "--out",
            out_dir,
            "--max-age-hours",
            "100000",
            "--require-full"
          ])
        end)
      end

    assert error.message =~ "full parity release gate failed"
    assert error.message =~ "blocking requirements:"
    assert error.message =~ "current_low_cost"
    assert error.message =~ "8720 rows remaining"
    assert error.message =~ "frontier_sanity: missing matched live evidence"
    assert error.message =~ "historical_research: missing matched live evidence"
    assert error.message =~ "live max_concurrency evidence is missing or inconsistent"
    assert error.message =~ "Runtime shape evidence is not complete"
    assert error.message =~ "claim claim.docs.livebooks_real_provider"
    refute error.message =~ "claim claim.product.public_api_installable"
    refute error.message =~ "claim claim.protocols.production_boundaries"
  end

  test "dashboard does not trust forged GEPA full summary without row provenance" do
    root = tmp_dir("dashboard-forged-gepa")

    dirs =
      Map.new(
        [
          :trace_dir,
          :overhead_dir,
          :optimizer_dir,
          :gepa_dir,
          :rag_tool_agent_dir,
          :rlm_dir,
          :live_matrix_dir,
          :results_dir,
          :gate_dir,
          :out_dir
        ],
        fn key -> {key, Path.join(root, Atom.to_string(key))} end
      )

    Enum.each(Map.values(dirs), &File.mkdir_p!/1)

    write_json!(Path.join(dirs.gepa_dir, "gepa-replication-forged.json"), %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-replication",
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "source" => %{"mode" => "input"},
      "summary" => %{
        "all_passing" => true,
        "full_gepa_replication" => true,
        "evidence_level" => "research_campaign"
      },
      "rows" =>
        Enum.map(gepa_rows(), fn row ->
          row
          |> Map.delete("dataset")
          |> Map.update!("results", &put_in(&1, ["dspy_gepa", "source"], "placeholder row"))
        end)
    })

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--trace-dir",
        dirs.trace_dir,
        "--overhead-dir",
        dirs.overhead_dir,
        "--optimizer-dir",
        dirs.optimizer_dir,
        "--gepa-dir",
        dirs.gepa_dir,
        "--rag-tool-agent-dir",
        dirs.rag_tool_agent_dir,
        "--rlm-dir",
        dirs.rlm_dir,
        "--live-matrix-dir",
        dirs.live_matrix_dir,
        "--results-dir",
        dirs.results_dir,
        "--gate-dir",
        dirs.gate_dir,
        "--out",
        dirs.out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(dirs.out_dir, "parity-dashboard-*.json"))
    dashboard = path |> File.read!() |> Jason.decode!()

    assert dashboard["lanes"]["gepa_replication"]["status"] == "failing"
    refute dashboard["lanes"]["gepa_replication"]["summary"]["full_gepa_replication"]

    gepa_claim =
      Enum.find(dashboard["claims"]["claims"], &(&1["id"] == "claim.gepa_replication.full"))

    refute gepa_claim["proven"]
  end

  test "require-full fails when the public claims inventory is unreadable" do
    root = tmp_dir("dashboard-missing-claims")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Dsex.Benchmark.Dashboard.run([
            "--out",
            out_dir,
            "--claims-file",
            Path.join(root, "missing-claims.json"),
            "--require-full"
          ])
        end)
      end

    assert error.message =~ "claim claims_inventory"
    assert error.message =~ "machine-readable public claims inventory exists"
    assert error.message =~ "missing_claims_file"
  end

  test "require-full failure summarizes campaign aggregate blockers" do
    root = tmp_dir("dashboard-campaign-blockers")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")

    Enum.each([results_dir, out_dir], &File.mkdir_p!/1)

    write_json!(Path.join(results_dir, "dsex-dspy-parity-campaign-test-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "provider" => "req_llm",
      "model" => "test-model",
      "coverage" => %{"covered" => 10, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "aggregate_gap" => 0.02}
    })

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Dsex.Benchmark.Dashboard.run([
            "--trace-dir",
            Path.join(root, "missing-trace"),
            "--overhead-dir",
            Path.join(root, "missing-overhead"),
            "--optimizer-dir",
            Path.join(root, "missing-optimizer"),
            "--rag-tool-agent-dir",
            Path.join(root, "missing-rag"),
            "--live-matrix-dir",
            Path.join(root, "missing-matrix"),
            "--results-dir",
            results_dir,
            "--out",
            out_dir,
            "--max-age-hours",
            "100000",
            "--require-full"
          ])
        end)
      end

    assert error.message =~ "live campaign coverage incomplete (10/8724 rows covered)"
    assert error.message =~ "live campaign parity thresholds not satisfied (gap 0.02)"
  end

  test "dashboard uses the freshest live matrix across canonical output dirs" do
    root = tmp_dir("dashboard-freshest-live-matrix")
    live_matrix_dir = Path.join(root, "tmp-live-matrix")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")

    Enum.each([live_matrix_dir, results_dir, out_dir], &File.mkdir_p!/1)

    stale_path = Path.join(live_matrix_dir, "live-matched-model-matrix-20260707T000000Z.json")

    write_json!(stale_path, live_matrix_artifact(100, 1.1455, "stale-matrix"))
    File.touch!(stale_path, {{2026, 1, 1}, {0, 0, 0}})

    fresh_path = Path.join(results_dir, "live-matched-model-matrix-20260707T000100Z.json")

    write_json!(fresh_path, live_matrix_artifact(2300, 26.3641, "fresh-matrix"))
    File.touch!(fresh_path, {{2026, 1, 1}, {0, 1, 0}})

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--live-matrix-dir",
        live_matrix_dir,
        "--results-dir",
        results_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()
    live_lane = dashboard["lanes"]["live_matched_model"]

    assert live_lane["artifact"]["path"] == fresh_path

    assert live_lane["summary"]["required_lanes"]["current_low_cost"]["coverage"][
             "covered_rows"
           ] == 2300

    assert live_lane["summary"]["required_lanes"]["current_low_cost"]["coverage"][
             "coverage_percent"
           ] == 26.3641
  end

  test "dashboard ignores stale prompt contracts on non-winning live candidates" do
    root = tmp_dir("dashboard-live-prompt-winners")
    live_matrix_dir = Path.join(root, "live-matrix")
    out_dir = Path.join(root, "out")
    Enum.each([live_matrix_dir, out_dir], &File.mkdir_p!/1)

    write_json!(Path.join(live_matrix_dir, "live-matched-model-matrix-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "models" => 4,
        "full_parity_models" => 0,
        "matrix_complete" => false,
        "dsex_instrumentation" => %{"complete" => true},
        "runtime_shape" => %{"complete" => true},
        "disagreements" => %{"count" => 0},
        "latency" => %{"complete" => true},
        "execution" => %{"complete" => true},
        "prompt_contract" => %{
          "complete" => false,
          "models_with_current_prompt_contract" => 2,
          "total_models" => 4
        },
        "required_lanes" => %{
          "current_low_cost" => %{
            "present" => true,
            "satisfied" => false,
            "satisfaction" => "unsatisfied",
            "full_evidence" => false,
            "models" => ["anthropic:claude-haiku-4-5", "gpt-5.4-mini"],
            "best_model" => "anthropic:claude-haiku-4-5",
            "best_status" => "research_sample",
            "coverage" => %{"covered_rows" => 3219, "expected_rows" => 8724}
          },
          "frontier_sanity" => %{
            "present" => true,
            "satisfied" => true,
            "satisfaction" => "evidence",
            "full_evidence" => false,
            "models" => ["anthropic:claude-sonnet-4-6", "gpt-5.5"],
            "best_model" => "anthropic:claude-sonnet-4-6",
            "best_status" => "research_sample"
          },
          "historical_research" => %{
            "present" => true,
            "satisfied" => true,
            "satisfaction" => "explicit_unavailable",
            "availability" => %{
              "status" => "explicit_unavailable",
              "note" => "legacy endpoints unavailable"
            },
            "full_evidence" => false,
            "models" => ["gpt-3.5-turbo"],
            "best_model" => "gpt-3.5-turbo",
            "best_status" => "smoke"
          }
        }
      },
      "models" => [
        live_model("anthropic:claude-haiku-4-5", ["current_low_cost"], true),
        live_model("gpt-5.4-mini", ["current_low_cost"], false),
        live_model("anthropic:claude-sonnet-4-6", ["frontier_sanity"], true),
        live_model("gpt-5.5", ["frontier_sanity"], false)
      ]
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--live-matrix-dir",
        live_matrix_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()

    live_blockers =
      dashboard["lanes"]["live_matched_model"]["summary"]["blocking_requirements"]

    refute Enum.any?(live_blockers, &(&1["kind"] == "prompt_contract_incomplete"))
    assert Enum.map(live_blockers, & &1["kind"]) == ["live_lane_full_evidence"]
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))

  defp write_gate_evidence!(dir, gate, mix_task) do
    write_json!(Path.join(dir, "gate-evidence-#{gate}-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "runner" => "dsex-gate-evidence",
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "gate" => gate,
      "command" => %{"executable" => "mix", "args" => [mix_task], "env" => []},
      "summary" => %{
        "mix_task" => mix_task,
        "passing" => true,
        "exit_status" => 0,
        "duration_ms" => 123
      },
      "output_tail" => "ok"
    })
  end

  defp live_model(model, lane_tags, prompt_current?) do
    %{
      "model" => model,
      "lane_tags" => lane_tags,
      "parity" => %{"latency_parity" => true},
      "proof" => %{
        "prompt_contract_current" => prompt_current?,
        "prompt_contract" => %{"dsex_req_llm" => if(prompt_current?, do: "v7", else: "v6")},
        "expected_prompt_contract" => %{"dsex_req_llm" => "v7"},
        "max_concurrency_consistent" => true
      }
    }
  end

  defp live_matrix_artifact(covered_rows, coverage_percent, run_id) do
    %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "models" => 1,
        "full_parity_models" => 0,
        "matrix_complete" => false,
        "dsex_instrumentation" => %{"complete" => true},
        "runtime_shape" => %{"complete" => true},
        "disagreements" => %{"count" => 0},
        "prompt_contract" => %{"complete" => true},
        "required_lanes" => %{
          "current_low_cost" => %{
            "present" => true,
            "full_evidence" => false,
            "models" => ["gpt-5.4-mini"],
            "best_status" => "research_sample",
            "coverage" => %{
              "covered_rows" => covered_rows,
              "expected_rows" => 8724,
              "remaining_rows" => 8724 - covered_rows,
              "coverage_percent" => coverage_percent,
              "full" => false
            },
            "cost" => %{"status" => "token_estimate"}
          },
          "frontier_sanity" => %{
            "present" => false,
            "full_evidence" => false,
            "models" => [],
            "best_status" => "missing"
          },
          "historical_research" => %{
            "present" => false,
            "full_evidence" => false,
            "models" => [],
            "best_status" => "missing"
          }
        },
        "run_id" => run_id
      }
    }
  end

  defp gepa_rows do
    Enum.map(
      [
        {"AIMEBench", "CoT"},
        {"HotpotQABench", "HotpotMultiHop"},
        {"hoverBench", "HoverMultiHop"},
        {"IFBench", "IFBenchCoT2StageProgram"},
        {"LiveBenchMathBench", "CoT"},
        {"Papillon", "PAPILLON"}
      ],
      fn {family, program} ->
        row = %{
          "family" => family,
          "program" => program,
          "model" => "gpt-4.1-mini-2025-04-14",
          "campaign_id" => "gepa-dashboard-test-campaign",
          "reflection_model" => "gpt-5-2026-01-01",
          "evidence_level" => "research_campaign",
          "metric_calls" => 150,
          "optimizer_budgets" => %{
            "baseline" => 1,
            "dspy_gepa" => 150,
            "dsex_gepa" => 150,
            "mipro_v2" => 150
          },
          "dataset" => %{
            "source" => "github.com/gepa-ai/gepa-artifact@abcdef1",
            "split" => "train_dev_test",
            "checksums" => %{
              "train" => "sha256:#{family}:train",
              "dev" => "sha256:#{family}:dev",
              "test" => "sha256:#{family}:test"
            }
          },
          "source_commits" => %{
            "dspy" => "stanfordnlp/dspy@abcdef1",
            "dsex" => "deepfates/dsex@abcdef2",
            "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
          },
          "token_cost" => %{
            "usd" => 1.25,
            "input_tokens" => 10_000,
            "output_tokens" => 2_000,
            "pricing_source" => "openai pricing table 2026-07-09"
          },
          "wall_clock_ms" => 12_345,
          "seed_variance" => %{"seeds" => [0, 1, 2], "stddev" => 0.01},
          "train_dev_test_gap" => %{
            "train" => 0.8,
            "dev" => 0.75,
            "test" => 0.73,
            "split_digests" => %{
              "train" => "sha256:#{family}:train",
              "dev" => "sha256:#{family}:dev",
              "test" => "sha256:#{family}:test"
            }
          },
          "results" => %{
            "baseline" => %{"score" => 0.5, "source" => "DSEx baseline runner artifact"},
            "dspy_gepa" => %{"score" => 0.6, "source" => "DSPy GEPA runner artifact"},
            "dsex_gepa" => %{"score" => 0.61, "source" => "DSEx GEPA runner artifact"},
            "mipro_v2" => %{"score" => 0.55, "source" => "DSPy MIPROv2 runner artifact"},
            "simba" => %{"score" => 0.56, "source" => "optional SIMBA comparator artifact"}
          }
        }

        if family == "Papillon" do
          Map.put(row, "metric_judge", %{
            "kind" => "papillon_quality_leakage",
            "model" => "openai/gpt-4.1-mini-2025-04-14",
            "quality_judge" =>
              "DSEx ChainOfThought JudgeQuality source-faithful pairwise order check",
            "leakage_judge" =>
              "DSEx ChainOfThought JudgeLeakage source-faithful pii leaked-count check",
            "score_formula" => "(quality + (1 - leakage)) / 2.0"
          })
        else
          row
        end
      end
    )
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
