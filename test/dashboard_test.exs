defmodule DashboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @local_mlx_fixture Path.expand(
                       "../benchmarks/results/local-mlx/local-mlx-ada199b-20260713.json",
                       __DIR__
                     )

  test "dashboard aggregates lane artifacts and require-full refuses missing lanes" do
    root = tmp_dir("dashboard")
    trace_dir = Path.join(root, "trace")
    failure_campaign_dir = Path.join(root, "failure-campaign")
    overhead_dir = Path.join(root, "overhead")
    optimizer_dir = Path.join(root, "optimizer")
    instruction_optimizer_dir = Path.join(root, "instruction-optimizer")
    gepa_dir = Path.join(root, "gepa")
    optimize_anything_dir = Path.join(root, "optimize-anything")
    rag_tool_agent_dir = Path.join(root, "rag-tool-agent")
    rlm_dir = Path.join(root, "rlm-benchmark")
    live_matrix_dir = Path.join(root, "live-matrix")
    results_dir = Path.join(root, "results")
    gate_dir = Path.join(root, "gate-evidence")
    out_dir = Path.join(root, "out")

    Enum.each(
      [
        trace_dir,
        failure_campaign_dir,
        overhead_dir,
        optimizer_dir,
        instruction_optimizer_dir,
        gepa_dir,
        optimize_anything_dir,
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
    write_failure_campaign!(failure_campaign_dir)

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

    write_instruction_optimizer_contract!(instruction_optimizer_dir)

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
      "evidence_tier" => "t3_paper_scale",
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 6,
        "passing" => 6,
        "all_passing" => true,
        "paper_protocol_complete" => true,
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
        "--failure-campaign-dir",
        failure_campaign_dir,
        "--overhead-dir",
        overhead_dir,
        "--optimizer-dir",
        optimizer_dir,
        "--instruction-optimizer-dir",
        instruction_optimizer_dir,
        "--gepa-dir",
        gepa_dir,
        "--optimize-anything-dir",
        optimize_anything_dir,
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
    assert dashboard["profile"]["id"] == "telos"
    refute dashboard["release_gate"]["passing"]

    assert dashboard["release_gate"]["blocking_lanes"] == [
             "failure_recovery",
             "gepa_replication",
             "live_matched_model",
             "live_provider_smoke",
             "optimize_anything",
             "rlm_benchmark",
             "public_claims"
           ]

    assert Enum.count(dashboard["release_gate"]["checks"]) ==
             length(dashboard["required_lanes"]) + 1

    assert dashboard["claims"]["status"] == "failing"

    assert dashboard["claims"]["summary"]["total"] ==
             length(dashboard["claims"]["claims"])

    assert dashboard["claims"]["summary"]["blocked"] == 6
    assert dashboard["claims"]["summary"]["non_blocking"] == 0

    proven_claim_ids =
      dashboard["claims"]["claims"]
      |> Enum.filter(&(&1["status"] == "proven"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert dashboard["claims"]["summary"]["proven"] == length(proven_claim_ids)
    assert "claim.local_mlx_weight_training.effectiveness" in proven_claim_ids

    assert [
             "claim.dspy_semantics.golden_trace",
             "claim.failure_recovery.deterministic_t0",
             "claim.optimizer_lift.full",
             "claim.performance.provider_free",
             "claim.product.public_api_installable",
             "claim.protocols.production_boundaries",
             "claim.rag_tools_agents.full"
           ] -- proven_claim_ids == []

    assert dashboard["lanes"]["product_package"]["status"] == "full"
    assert dashboard["lanes"]["livebook_execute"]["status"] == "full"
    assert dashboard["lanes"]["protocol_gates"]["status"] == "full"
    assert dashboard["lanes"]["live_provider_smoke"]["status"] == "missing"
    assert dashboard["lanes"]["failure_recovery"]["status"] == "passing"
    assert dashboard["lanes"]["failure_recovery"]["passing"]
    refute dashboard["lanes"]["failure_recovery"]["full_evidence"]

    assert get_in(dashboard, [
             "lanes",
             "failure_recovery",
             "summary",
             "authority",
             "deterministic_complete"
           ])

    assert Enum.map(
             dashboard["claims"]["blocking_requirements"],
             &{&1["claim_id"], &1["missing_requirements"]}
           ) == [
             {"claim.docs.livebooks_real_provider", ["live.provider.smoke"]},
             {"claim.live_matched_model.full_parity", ["live_matched_model.full"]},
             {"claim.gepa_replication.full", ["gepa_replication.full"]},
             {"claim.optimize_anything.non_prompt_effectiveness",
              ["optimize_anything.non_prompt.full"]},
             {"claim.rlm.provider_free_benchmark", ["rlm_benchmark.full"]},
             {"claim.failure_recovery.live", ["failure_recovery.live.full"]}
           ]

    active_live_claim =
      Enum.find(
        dashboard["claims"]["claims"],
        &(&1["id"] == "claim.live_matched_model.full_parity")
      )

    assert active_live_claim["status"] == "blocked"
    assert active_live_claim["decision"] == "active_gap"
    assert active_live_claim["release"] == "telos"

    assert dashboard["lanes"]["golden_trace"]["status"] == "full"
    assert dashboard["lanes"]["rlm_benchmark"]["status"] == "passing"
    refute dashboard["lanes"]["rlm_benchmark"]["full_evidence"]
    refute dashboard["lanes"]["rlm_benchmark"]["summary"]["paper_protocol_complete"]

    assert Enum.any?(
             dashboard["lanes"]["rlm_benchmark"]["blocking_requirements"],
             &(&1["check"] == "dataset_protocol")
           )

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
    assert dashboard["lanes"]["instruction_optimizer_contract"]["status"] == "full"

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

    assert dashboard["lanes"]["gepa_replication"]["status"] == "failing"
    refute dashboard["lanes"]["gepa_replication"]["summary"]["full_gepa_replication"]
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_families"] == []
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_fields"] != []

    assert dashboard["lanes"]["rag_tool_agent"]["status"] == "full"

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Dsex.Benchmark.Dashboard.run([
            "--trace-dir",
            trace_dir,
            "--failure-campaign-dir",
            failure_campaign_dir,
            "--overhead-dir",
            overhead_dir,
            "--optimizer-dir",
            optimizer_dir,
            "--instruction-optimizer-dir",
            instruction_optimizer_dir,
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

  test "instruction optimizer lane selects the newest pinned structural contract" do
    root = tmp_dir("dashboard-instruction-optimizer-newest")
    contract_dir = Path.join(root, "contracts")
    out_dir = Path.join(root, "out")
    Enum.each([contract_dir, out_dir], &File.mkdir_p!/1)

    old_path =
      write_instruction_optimizer_contract!(contract_dir,
        name: "instruction-optimizer-contract-old.json",
        structural_complete: false
      )

    newest_path =
      write_instruction_optimizer_contract!(contract_dir,
        name: "instruction-optimizer-contract-newest.json"
      )

    File.touch!(old_path, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(newest_path, {{2026, 1, 1}, {0, 0, 1}})

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--instruction-optimizer-dir",
        contract_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "1"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()
    lane = dashboard["lanes"]["instruction_optimizer_contract"]

    assert lane["artifact"]["path"] == newest_path
    assert lane["status"] == "full"
    assert lane["full_evidence"]
    assert lane["summary"]["structural_contract_complete"]
    assert lane["summary"]["authority"]["complete"]
  end

  test "local MLX lane requires a verified valid fresh successful artifact" do
    root = tmp_dir("dashboard-local-mlx")

    scenarios = [
      {"missing", :missing, "missing", false},
      {"rejected", :rejected, "failing", false},
      {"tampered", :tampered, "failing", false},
      {"stale", :stale, "stale", false},
      {"valid", :valid, "full", true}
    ]

    Enum.each(scenarios, fn {name, artifact_kind, expected_status, full_evidence} ->
      local_mlx_dir = Path.join(root, name)
      out_dir = Path.join(root, "#{name}-out")
      Enum.each([local_mlx_dir, out_dir], &File.mkdir_p!/1)

      case artifact_kind do
        :missing -> :ok
        :rejected -> write_local_mlx_artifact!(local_mlx_dir, status: "rejected")
        :tampered -> write_local_mlx_artifact!(local_mlx_dir, tampered: true)
        :stale -> write_local_mlx_artifact!(local_mlx_dir, generated_at: ~U[2000-01-01 00:00:00Z])
        :valid -> write_local_mlx_artifact!(local_mlx_dir)
      end

      dashboard = run_local_mlx_dashboard!(local_mlx_dir, out_dir)
      lane = dashboard["lanes"]["local_mlx_weight_training"]

      assert lane["status"] == expected_status
      assert lane["full_evidence"] == full_evidence
      assert lane["passing"] == artifact_kind in [:stale, :valid]

      if artifact_kind in [:rejected, :tampered] do
        assert [%{"kind" => "local_mlx_artifact_rejected"}] =
                 lane["blocking_requirements"]
      end
    end)
  end

  test "local MLX lane selects the newest candidate without falling back" do
    root = tmp_dir("dashboard-local-mlx-newest")
    local_mlx_dir = Path.join(root, "artifacts")
    out_dir = Path.join(root, "out")
    Enum.each([local_mlx_dir, out_dir], &File.mkdir_p!/1)

    old_path = write_local_mlx_artifact!(local_mlx_dir, name: "local-mlx-old.json")

    newest_path =
      write_local_mlx_artifact!(local_mlx_dir,
        name: "local-mlx-newest.json",
        status: "rejected"
      )

    File.touch!(old_path, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(newest_path, {{2026, 1, 1}, {0, 0, 1}})

    lane =
      local_mlx_dir
      |> run_local_mlx_dashboard!(out_dir)
      |> get_in(["lanes", "local_mlx_weight_training"])

    assert lane["artifact"]["path"] == newest_path
    assert lane["status"] == "failing"
    refute lane["full_evidence"]
  end

  test "instruction optimizer full evidence requires the dashboard code revision" do
    root = tmp_dir("dashboard-instruction-optimizer-revision")
    contract_dir = Path.join(root, "contracts")
    out_dir = Path.join(root, "out")
    Enum.each([contract_dir, out_dir], &File.mkdir_p!/1)

    write_instruction_optimizer_contract!(contract_dir, git_sha: "recent-but-wrong-sha")
    dashboard = run_instruction_optimizer_dashboard!(contract_dir, out_dir)
    lane = dashboard["lanes"]["instruction_optimizer_contract"]

    assert lane["fresh"]
    assert lane["status"] == "failing"
    refute lane["full_evidence"]
    refute lane["summary"]["implementation_revision_matches"]

    assert [blocker] =
             Enum.filter(
               lane["blocking_requirements"],
               &(&1["kind"] == "instruction_optimizer_implementation_revision_mismatch")
             )

    assert blocker["artifact_git_sha"] == "recent-but-wrong-sha"
    assert blocker["expected_git_sha"] == dashboard["git_sha"]
    assert blocker["message"] =~ "Stale instruction-optimizer evidence"
    assert blocker["message"] =~ "recent-but-wrong-sha"
    assert blocker["message"] =~ dashboard["git_sha"]

    write_instruction_optimizer_contract!(contract_dir, git_sha: dashboard["git_sha"])
    dashboard = run_instruction_optimizer_dashboard!(contract_dir, out_dir)
    lane = dashboard["lanes"]["instruction_optimizer_contract"]

    assert lane["status"] == "full"
    assert lane["full_evidence"]
    assert lane["summary"]["implementation_revision_matches"]

    refute Enum.any?(
             lane["blocking_requirements"],
             &(&1["kind"] == "instruction_optimizer_implementation_revision_mismatch")
           )
  end

  test "missing stale failed or unpinned structural evidence stays red and blocks optimizer parity" do
    scenarios = [
      {"missing", :missing, "missing"},
      {"stale", [generated_at: "2020-01-01T00:00:00Z"], "stale"},
      {"failed", [structural_complete: false], "failing"},
      {"unpinned", [dspy_version: "3.3.0"], "failing"}
    ]

    Enum.each(scenarios, fn {name, contract_opts, expected_status} ->
      root = tmp_dir("dashboard-instruction-optimizer-#{name}")
      contract_dir = Path.join(root, "contracts")
      optimizer_dir = Path.join(root, "optimizer")
      out_dir = Path.join(root, "out")
      Enum.each([contract_dir, optimizer_dir, out_dir], &File.mkdir_p!/1)

      if contract_opts != :missing do
        write_instruction_optimizer_contract!(contract_dir, contract_opts)
      end

      write_json!(Path.join(optimizer_dir, "optimizer-lift-parity-full.json"), %{
        "schema_version" => 1,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "git_sha" => "abc",
        "summary" => %{
          "total" => 1,
          "passing" => 1,
          "all_passing" => true,
          "full_optimizer_parity" => true
        },
        "rows" => []
      })

      capture_io(fn ->
        Mix.Task.reenable("dsex.benchmark.dashboard")

        Mix.Tasks.Dsex.Benchmark.Dashboard.run([
          "--instruction-optimizer-dir",
          contract_dir,
          "--optimizer-dir",
          optimizer_dir,
          "--out",
          out_dir,
          "--max-age-hours",
          "1"
        ])
      end)

      [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
      dashboard = dashboard_path |> File.read!() |> Jason.decode!()
      contract_lane = dashboard["lanes"]["instruction_optimizer_contract"]
      optimizer_lane = dashboard["lanes"]["optimizer_lift"]

      assert contract_lane["status"] == expected_status
      refute contract_lane["full_evidence"]
      assert optimizer_lane["status"] == "sample"
      refute optimizer_lane["full_evidence"]
      refute optimizer_lane["summary"]["full_optimizer_parity"]

      optimizer_claim =
        Enum.find(dashboard["claims"]["claims"], &(&1["id"] == "claim.optimizer_lift.full"))

      assert optimizer_claim["status"] == "blocked"
    end)
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

  test "profiles select claim requirements and default keeps telos gaps visible" do
    root = tmp_dir("dashboard-profile")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--profile",
        "v0.1",
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = path |> File.read!() |> Jason.decode!()

    assert dashboard["profile"]["id"] == "v0.1"

    assert dashboard["claims"]["summary"]["total"] ==
             length(dashboard["claims"]["claims"])

    assert dashboard["required_lanes"] == [
             "failure_recovery",
             "golden_trace",
             "live_provider_smoke",
             "livebook_execute",
             "local_mlx_weight_training",
             "optimize_anything",
             "product_package",
             "protocol_gates"
           ]

    refute Enum.any?(dashboard["claims"]["claims"], &(&1["release"] == "telos"))

    assert_raise Mix.Error, ~r/unknown release profile/, fn ->
      Mix.Tasks.Dsex.Benchmark.Dashboard.run(["--profile", "unknown", "--out", out_dir])
    end
  end

  test "failure recovery authority rejects summaries and legacy files but accepts valid live rows" do
    root = tmp_dir("dashboard-failure-authority")
    deterministic_dir = Path.join(root, "deterministic")
    live_dir = Path.join(root, "live")
    forged_dir = Path.join(root, "forged")
    legacy_dir = Path.join(root, "legacy")
    Enum.each([deterministic_dir, live_dir, forged_dir, legacy_dir], &File.mkdir_p!/1)

    write_failure_campaign!(deterministic_dir, reported_release_complete: true)
    write_failure_campaign!(live_dir, live: true)
    write_failure_campaign!(forged_dir, live: true, forge_live_summary: true)

    write_json!(Path.join(legacy_dir, "failure-campaign-legacy.json"), %{
      "schema_version" => 2,
      "runner" => "dsex-failure-campaign",
      "summary" => %{"deterministic_complete" => true, "release_complete" => true}
    })

    deterministic = run_failure_dashboard!(root, "deterministic-out", deterministic_dir)
    deterministic_lane = deterministic["lanes"]["failure_recovery"]
    assert deterministic_lane["passing"]
    refute deterministic_lane["full_evidence"]
    assert deterministic_lane["summary"]["reported_summary"]["release_complete"]
    refute deterministic_lane["summary"]["authority"]["live_complete"]

    live = run_failure_dashboard!(root, "live-out", live_dir)
    assert live["lanes"]["failure_recovery"]["status"] == "full"
    assert live["lanes"]["failure_recovery"]["full_evidence"]

    forged = run_failure_dashboard!(root, "forged-out", forged_dir)
    refute forged["lanes"]["failure_recovery"]["full_evidence"]

    assert forged["lanes"]["failure_recovery"]["summary"]["authority"][
             "missing_live_rows"
           ] == ["provider_retry_timeout_idempotency_live"]

    legacy = run_failure_dashboard!(root, "legacy-out", legacy_dir)
    assert legacy["lanes"]["failure_recovery"]["status"] == "unverifiable"
    refute legacy["lanes"]["failure_recovery"]["passing"]

    refute legacy["lanes"]["failure_recovery"]["summary"]["authority"][
             "run_envelope_verified"
           ]
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))

  defp run_failure_dashboard!(root, out_name, failure_dir) do
    out_dir = Path.join(root, out_name)
    File.mkdir_p!(out_dir)

    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--failure-campaign-dir",
        failure_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    path |> File.read!() |> Jason.decode!()
  end

  defp write_failure_campaign!(dir, opts \\ []) do
    File.mkdir_p!(dir)

    cases =
      Enum.map(
        ~w(
          task_cancellation_releases_admission
          task_timeout_is_explicit_and_terminal
          async_concurrency_is_bounded
          partial_stream_failure_is_terminal
          training_retry_and_idempotency_are_bounded
          http_retrieval_retry_timeout_and_idempotency
          mcp_retry_timeout_and_idempotency
          mipro_v2_durable_resume_and_tamper
          simba_durable_resume_and_tamper
        ),
        fn id ->
          %{
            "id" => id,
            "evidence_kind" => "deterministic",
            "iterations" => 10,
            "passing_iterations" => 10,
            "failing_iterations" => 0,
            "flake_rate" => 0.0,
            "passing" => true,
            "outcomes" =>
              Enum.map(1..10, fn iteration ->
                %{
                  "iteration" => iteration,
                  "passing" => true,
                  "duration_ms" => 1,
                  "evidence" => failure_case_evidence(id)
                }
              end)
          }
        end
      )

    live_cases =
      if Keyword.get(opts, :live, false) do
        Enum.map(
          ~w(
            provider_retry_timeout_idempotency_live
            retrieval_and_tool_agent_recovery_live
          ),
          fn id ->
            %{
              "id" => id,
              "required" => true,
              "evidence_kind" => "live",
              "status" => "complete",
              "passing" => true,
              "started_at" => "2026-07-07T00:00:00Z",
              "completed_at" => "2026-07-07T00:01:00Z",
              "iterations" => 2,
              "passing_iterations" => 2,
              "failing_iterations" => 0,
              "flake_rate" => 0.0,
              "outcomes" =>
                Enum.map(1..2, fn iteration ->
                  %{
                    "iteration" => iteration,
                    "passing" => true,
                    "duration_ms" => 1,
                    "evidence" =>
                      if Keyword.get(opts, :forge_live_summary, false) and
                           id == "provider_retry_timeout_idempotency_live" do
                        Map.put(failure_live_evidence(id), "attempts", 1)
                      else
                        failure_live_evidence(id)
                      end
                  }
                end),
              "checks" => failure_live_checks(id),
              "runtime" => %{
                "leak_free" => true,
                "leaks" => %{
                  "admission_active" => 0,
                  "admission_queued" => 0,
                  "added_linked_tasks" => 0,
                  "added_unlinked_tasks" => 0,
                  "added_processes" => 0,
                  "added_ports" => 0,
                  "added_telemetry_handlers" => 0
                }
              }
            }
          end
        )
      else
        []
      end

    artifact = %{
      "schema_version" => 3,
      "runner" => "dsex-failure-campaign",
      "evidence_tier" => "t0_deterministic_failure_recovery",
      "configuration" => %{"iterations" => 10, "required_flake_iterations" => 10},
      "summary" => %{
        "deterministic_complete" => true,
        "live_complete" => Keyword.get(opts, :reported_release_complete, false),
        "release_complete" => Keyword.get(opts, :reported_release_complete, false)
      },
      "runtime" => %{
        "before" => %{
          "admission" => %{"active" => 0, "queued" => 0},
          "linked_tasks" => 0,
          "unlinked_tasks" => 0,
          "processes" => 1,
          "ports" => 0,
          "telemetry_handlers" => 0
        },
        "after" => %{
          "admission" => %{"active" => 0, "queued" => 0},
          "linked_tasks" => 0,
          "unlinked_tasks" => 0,
          "processes" => 1,
          "ports" => 0,
          "telemetry_handlers" => 0
        },
        "leaks" => %{
          "admission_active" => 0,
          "admission_queued" => 0,
          "added_linked_tasks" => 0,
          "added_unlinked_tasks" => 0,
          "added_processes" => 0,
          "added_ports" => 0,
          "added_telemetry_handlers" => 0
        },
        "leak_free" => true
      },
      "telemetry" => %{
        "handler_detached" => true,
        "balanced_spans" => true,
        "metadata_secret_free" => true,
        "event_counts" => %{}
      },
      "secret_scan" => %{
        "passing" => true,
        "configured_secret_hits" => 0,
        "credential_pattern_hits" => 0,
        "payload_sha256" => "sha256:test"
      },
      "cases" => cases,
      "live_cases" => live_cases,
      "remaining" => [],
      "scope" => Enum.map(cases, & &1["id"])
    }

    clock = fn -> ~U[2026-07-07 00:02:00Z] end

    context =
      DSEx.BenchmarkTruth.RunContext.new!(
        source_commits: %{"dsex" => "deepfates/dsex@abc"},
        workspace_state: "synthetic",
        clock: clock
      )

    path = Path.join(dir, "failure-campaign-test.json")

    %{path: written_path} =
      DSEx.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, context)

    written_path
  end

  defp failure_case_evidence("task_cancellation_releases_admission"),
    do: %{"task_alive" => false, "cancellation" => "terminal"}

  defp failure_case_evidence("task_timeout_is_explicit_and_terminal"),
    do: %{"outcome" => "timeout", "worker_terminated" => true}

  defp failure_case_evidence("async_concurrency_is_bounded"),
    do: %{"ordered" => true, "peak" => 2, "limit" => 2}

  defp failure_case_evidence("partial_stream_failure_is_terminal"),
    do: %{"terminal_errors" => 1, "statuses" => ["started", "error"]}

  defp failure_case_evidence("training_retry_and_idempotency_are_bounded"),
    do: %{"attempts" => 3, "max_attempts" => 3, "idempotency_header_stable" => true}

  defp failure_case_evidence("http_retrieval_retry_timeout_and_idempotency"),
    do: %{
      "attempts" => 3,
      "max_attempts" => 3,
      "idempotency_header_stable" => true,
      "terminal_status" => 200
    }

  defp failure_case_evidence("mcp_retry_timeout_and_idempotency"),
    do: %{
      "initialize_attempts" => 2,
      "list_attempts" => 2,
      "max_attempts" => 3,
      "idempotency_header_present" => true,
      "terminal_tool_count" => 1
    }

  defp failure_case_evidence(_optimizer),
    do: %{
      "exact_resume" => true,
      "tamper_rejected" => true,
      "checkpoint_payload_included" => false
    }

  defp failure_live_evidence("provider_retry_timeout_idempotency_live"),
    do: %{
      "provider" => "openai",
      "model" => "gpt-test",
      "attempts" => 2,
      "max_attempts" => 2,
      "injected_status" => 429,
      "terminal_status" => 200,
      "idempotency_header_stable" => true,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "cost" => %{}
    }

  defp failure_live_evidence("retrieval_and_tool_agent_recovery_live"),
    do: %{
      "provider" => "openai",
      "model" => "gpt-test",
      "retrieval_attempts" => 2,
      "retrieval_injected_error" => "closed",
      "retrieval_terminal_network" => "httpbin.org",
      "tool_calls" => 1,
      "submit_calls" => 1
    }

  defp failure_live_checks("provider_retry_timeout_idempotency_live") do
    Enum.map(
      ~w(repeated_zero_flakes runtime_leak_free real_provider_terminal_success bounded_retry_after_injected_429 stable_idempotency_key positive_provider_usage),
      &%{"id" => &1, "passing" => true}
    )
  end

  defp failure_live_checks("retrieval_and_tool_agent_recovery_live") do
    Enum.map(
      ~w(repeated_zero_flakes runtime_leak_free live_retrieval_recovered provider_backed_tool_agent_completed),
      &%{"id" => &1, "passing" => true}
    )
  end

  defp write_instruction_optimizer_contract!(dir, opts \\ []) do
    sources = [
      {"dspy/propose/grounded_proposer.py",
       "c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3"},
      {"dspy/teleprompt/bootstrap.py",
       "0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255"},
      {"dspy/teleprompt/mipro_optimizer_v2.py",
       "6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3"},
      {"dspy/teleprompt/simba.py",
       "4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55"},
      {"dspy/teleprompt/simba_utils.py",
       "ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c"},
      {"dspy/teleprompt/utils.py",
       "218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182"}
    ]

    structural_complete = Keyword.get(opts, :structural_complete, true)
    path = Path.join(dir, Keyword.get(opts, :name, "instruction-optimizer-contract-current.json"))

    write_json!(path, %{
      "schema_version" => 1,
      "evidence_tier" => "t1_instruction_optimizer_differential_contract",
      "generated_at" =>
        Keyword.get(opts, :generated_at, DateTime.utc_now() |> DateTime.to_iso8601()),
      "git_sha" => Keyword.get(opts, :git_sha, dashboard_git_sha()),
      "dspy" => %{
        "version" => Keyword.get(opts, :dspy_version, "3.3.0b1"),
        "commit" => "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f",
        "sources" =>
          Enum.map(sources, fn {path, hash} ->
            %{"path" => path, "sha256" => hash}
          end)
      },
      "summary" => %{
        "required_cases" => 10,
        "required_passing" => if(structural_complete, do: 10, else: 9),
        "structural_contract_complete" => structural_complete,
        "exact_sampler_sequence_parity" => false,
        "paper_protocol_complete" => false,
        "full_optimizer_parity" => false
      },
      "declared_native_deviations" => [%{"id" => "optimizer_rng_sequence"}],
      "rows" => []
    })

    path
  end

  defp run_instruction_optimizer_dashboard!(contract_dir, out_dir) do
    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--instruction-optimizer-dir",
        contract_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "1"
      ])
    end)

    out_dir
    |> Path.join("parity-dashboard-*.json")
    |> Path.wildcard()
    |> Enum.max_by(&File.stat!(&1).mtime)
    |> File.read!()
    |> Jason.decode!()
  end

  defp run_local_mlx_dashboard!(local_mlx_dir, out_dir) do
    capture_io(fn ->
      Mix.Task.reenable("dsex.benchmark.dashboard")

      Mix.Tasks.Dsex.Benchmark.Dashboard.run([
        "--local-mlx-dir",
        local_mlx_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    out_dir
    |> Path.join("parity-dashboard-*.json")
    |> Path.wildcard()
    |> Enum.max_by(&File.stat!(&1).mtime)
    |> File.read!()
    |> Jason.decode!()
  end

  defp write_local_mlx_artifact!(dir, opts \\ []) do
    artifact = @local_mlx_fixture |> File.read!() |> Jason.decode!()
    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])
    payload = if status = opts[:status], do: Map.put(payload, "status", status), else: payload
    clock = fn -> Keyword.get(opts, :generated_at, DateTime.utc_now()) end

    artifact =
      DSEx.BenchmarkTruth.RunContext.new!(
        source_commits: %{"dsex" => "deepfates/dsex@dashboard-test"},
        workspace_state: "clean",
        clock: clock
      )
      |> DSEx.BenchmarkTruth.RunContext.finish(payload)

    artifact =
      if opts[:tampered], do: put_in(artifact, ["fused", "accuracy"], 1.0), else: artifact

    path = Path.join(dir, Keyword.get(opts, :name, "local-mlx-test.json"))
    write_json!(path, artifact)
    path
  end

  defp dashboard_git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(sha)
  end

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
            "scope" => "full",
            "max_per_split" => nil,
            "split_counts" => %{
              "train" => 100,
              "dev" => 50,
              "test" => 50
            },
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

        row =
          if family == "hoverBench" do
            put_in(row, ["dataset", "retrieval"], %{
              "verified" => true,
              "implementation" => "upstream_python_bm25s",
              "corpus_checksum" => "sha256:" <> String.duplicate("1", 64),
              "index_checksum" => "sha256:" <> String.duplicate("2", 64)
            })
          else
            row
          end

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
