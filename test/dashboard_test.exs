defmodule DashboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "dashboard aggregates lane artifacts and require-full refuses missing lanes" do
    root = tmp_dir("dashboard")
    trace_dir = Path.join(root, "trace")
    overhead_dir = Path.join(root, "overhead")
    optimizer_dir = Path.join(root, "optimizer")
    rag_tool_agent_dir = Path.join(root, "rag-tool-agent")
    live_matrix_dir = Path.join(root, "live-matrix")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")

    Enum.each(
      [
        trace_dir,
        overhead_dir,
        optimizer_dir,
        rag_tool_agent_dir,
        live_matrix_dir,
        results_dir,
        out_dir
      ],
      &File.mkdir_p!/1
    )

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
        "--rag-tool-agent-dir",
        rag_tool_agent_dir,
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

    refute dashboard["full_parity"]
    assert dashboard["performance_claim_supported"]
    refute dashboard["release_gate"]["passing"]
    assert dashboard["release_gate"]["blocking_lanes"] == ["live_matched_model"]
    assert Enum.count(dashboard["release_gate"]["checks"]) == 5
    assert dashboard["lanes"]["golden_trace"]["status"] == "full"
    assert dashboard["lanes"]["provider_free_overhead"]["status"] == "full"
    assert dashboard["lanes"]["live_matched_model"]["status"] == "failing"
    assert dashboard["lanes"]["live_matched_model"]["summary"]["matrix_complete"] == false
    live_blockers = dashboard["lanes"]["live_matched_model"]["summary"]["blocking_requirements"]

    assert Enum.map(live_blockers, & &1["kind"]) == [
             "live_lane_full_evidence",
             "live_lane_missing",
             "live_lane_missing",
             "live_latency_parity_false",
             "prompt_contract_incomplete",
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
             %{"kind" => "prompt_contract_incomplete"},
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
            "--rag-tool-agent-dir",
            rag_tool_agent_dir,
            "--live-matrix-dir",
            live_matrix_dir,
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

    assert error.message =~ "full parity release gate failed"
    assert error.message =~ "blocking requirements:"
    assert error.message =~ "current_low_cost"
    assert error.message =~ "8720 rows remaining"
    assert error.message =~ "frontier_sanity: missing matched live evidence"
    assert error.message =~ "historical_research: missing matched live evidence"
    assert error.message =~ "Runtime shape evidence is not complete"
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

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))

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

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
