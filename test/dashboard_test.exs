defmodule DashboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @local_mlx_fixture Path.expand(
                       "../benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json",
                       __DIR__
                     )

  @tag :evidence_infrastructure
  test "dashboard aggregates lane artifacts and require-ready refuses missing lanes" do
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
      "git_sha" => dashboard_git_sha(),
      "summary" => %{
        "total" => 6,
        "passing" => 6,
        "all_cases_passing" => true,
        "prediction_parity" => true,
        "tool_trace_parity" => true,
        "imp_semantic_checks" => %{"all_passing" => true, "passing" => 4, "total" => 4}
      }
    })

    write_overhead_artifact!(overhead_dir)

    write_json!(Path.join(optimizer_dir, "optimizer-lift-parity-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "total" => 10,
        "passing" => 10,
        "all_passing" => true,
        "direct_comparisons" => 7,
        "imp_only_or_deviation" => 3,
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
          "comparison_status" => "imp_only",
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
      "runner" => "imp-gepa-replication",
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

    write_json!(
      Path.join(rag_tool_agent_dir, "rag-tool-agent-parity-20260707T000000Z.json"),
      source_bound_rag_tool_agent_artifact()
    )

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

    write_json!(Path.join(results_dir, "imp-dspy-parity-campaign-test-20260707T000000Z.json"), %{
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
        "imp_instrumentation" => %{
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
          "mean_message_chars_ratio_imp_over_dspy" => 1.05,
          "mean_raw_chars_ratio_imp_over_dspy" => 0.25,
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
          "directions" => %{"imp_only_pass" => 1, "dspy_only_pass" => 1, "both_fail" => 1}
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
              "ratio_imp_over_dspy" => 1.62,
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
          "latency" => %{"latency_ratio_imp_over_dspy" => 1.62},
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
      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--profile",
        "telos",
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

    assert dashboard["schema_version"] == 3

    assert Enum.all?(dashboard["lanes"], fn {_id, lane} ->
             Map.has_key?(lane, "candidate_eligibility") and not Map.has_key?(lane, "admission")
           end)

    refute dashboard["profile_ready"]
    assert dashboard["provider_free_overhead_regression_guard_passed"]
    assert dashboard["profile"]["id"] == "telos"
    refute dashboard["profile_gate"]["passing"]

    assert dashboard["profile_gate"]["blocking_lanes"] == [
             "failure_recovery",
             "gepa_replication",
             "live_matched_model",
             "live_provider_smoke",
             "optimize_anything",
             "rag_tool_agent",
             "rlm_benchmark"
           ]

    expected_claim_checks =
      dashboard["claims"]["claims"]
      |> Enum.filter(&(&1["gate_policy"] == "blocking"))
      |> Enum.flat_map(& &1["requirements"])
      |> length()

    assert Enum.count(dashboard["profile_gate"]["checks"]) == expected_claim_checks

    assert dashboard["claims"]["status"] == "failing"

    assert dashboard["claims"]["summary"]["total"] ==
             length(dashboard["claims"]["claims"])

    assert dashboard["claims"]["summary"]["blocked"] ==
             length(dashboard["claims"]["blocking_requirements"])

    # 11 evidence-backed informational conformance claims from the admission
    # campaign plus the 8 informational census claims for previously unclaimed
    # public surfaces (claims census reconciliation, PR #16).
    assert dashboard["claims"]["summary"]["informational"] == 19

    proven_claim_ids =
      dashboard["claims"]["claims"]
      |> Enum.filter(&(&1["evidence_state"] == "proven"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    assert dashboard["claims"]["summary"]["proven"] == length(proven_claim_ids)
    assert "claim.local_mlx_weight_training.effectiveness" in proven_claim_ids

    assert [
             "claim.dspy_semantics.golden_trace",
             "claim.evaluation.auto_evaluation.semantic_conformance",
             "claim.failure_recovery.deterministic_t0",
             "claim.optimizer.bootstrap_few_shot.semantic_conformance",
             "claim.optimizer.avatar_actor.semantic_conformance",
             "claim.optimizer.avatar_optimizer.semantic_conformance",
             "claim.optimizer.bootstrap_finetune.semantic_conformance",
             "claim.optimizer.better_together.semantic_conformance",
             "claim.optimizer.copro.semantic_conformance",
             "claim.optimizer.ensemble.semantic_conformance",
             "claim.optimizer.mmgrpo.semantic_conformance",
             "claim.optimizer.random_search.semantic_conformance",
             "claim.runtime.provider_free_overhead_guard",
             "claim.product.public_api_installable",
             "claim.protocols.production_boundaries",
             "claim.rag.provider_free_contract",
             "claim.react.provider_free_tool_contract",
             "claim.react_v2.provider_free_recovery_contract",
             "claim.mcp.in_process_import_contract",
             "claim.agents.policy_denial_contract",
             "claim.code_act.provider_free_execution_contract",
             "claim.program_of_thought.safe_eval_contract",
             "claim.streaming.incremental_field_contract",
             "claim.async.ordered_stream_contract",
             "claim.persistence.credential_redaction_contract"
           ] -- proven_claim_ids == []

    assert dashboard["lanes"]["product_package"]["status"] == "full"
    assert dashboard["lanes"]["livebook_execute"]["status"] == "full"
    assert dashboard["lanes"]["protocol_gates"]["status"] == "full"
    assert dashboard["lanes"]["auto_evaluation_contract"]["status"] == "full"
    assert dashboard["lanes"]["auto_evaluation_contract"]["passing"]
    assert dashboard["lanes"]["auto_evaluation_contract"]["full_evidence"]

    assert dashboard["lanes"]["auto_evaluation_contract"]["candidate_eligibility"][
             "policy"
           ] == "immutable_admission"

    assert dashboard["lanes"]["auto_evaluation_contract"]["candidate_eligibility"][
             "eligible"
           ]

    assert dashboard["lanes"]["bootstrap_few_shot_differential"]["status"] == "full"
    assert dashboard["lanes"]["bootstrap_few_shot_differential"]["passing"]
    assert dashboard["lanes"]["random_search_differential"]["status"] == "full"
    assert dashboard["lanes"]["random_search_differential"]["passing"]
    assert dashboard["lanes"]["copro_isolation"]["status"] == "full"
    assert dashboard["lanes"]["copro_isolation"]["passing"]

    for lane_id <- ~w(
          avatar_actor_differential
          avatar_optimizer_differential
          bootstrap_finetune_differential
          better_together_differential
          ensemble_differential
          mmgrpo_differential
        ) do
      assert dashboard["lanes"][lane_id]["status"] == "full"
      assert dashboard["lanes"][lane_id]["passing"]
    end

    assert get_in(dashboard, [
             "lanes",
             "auto_evaluation_contract",
             "summary",
             "passing_cases"
           ]) == 6

    assert get_in(dashboard, [
             "lanes",
             "auto_evaluation_contract",
             "summary",
             "contract_complete"
           ])

    refute get_in(dashboard, [
             "lanes",
             "auto_evaluation_contract",
             "summary",
             "natural_data_quality"
           ])

    assert get_in(dashboard, [
             "lanes",
             "bootstrap_few_shot_differential",
             "summary",
             "matched"
           ])

    assert get_in(dashboard, [
             "lanes",
             "random_search_differential",
             "summary",
             "matched"
           ])

    assert get_in(dashboard, [
             "lanes",
             "copro_isolation",
             "summary",
             "deterministic_observations_verified"
           ]) == 5

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

    blockers =
      Map.new(
        dashboard["claims"]["blocking_requirements"],
        &{&1["claim_id"], &1["missing_requirements"]}
      )

    assert blockers["claim.docs.livebooks_real_provider"] == ["live.provider.smoke"]
    assert blockers["claim.live_matched_model.full_parity"] == ["live_matched_model.full"]
    assert blockers["claim.gepa_replication.full"] == ["gepa_replication.full"]

    assert blockers["claim.optimize_anything.non_prompt_effectiveness"] ==
             ["optimize_anything.non_prompt.full"]

    assert blockers["claim.rag.hotpot_retrieval.effectiveness"] ==
             ["rag.hotpot_retrieval.effectiveness"]

    assert blockers["claim.tools.bfcl_selection.effectiveness"] ==
             ["tools.bfcl_selection.effectiveness"]

    assert blockers["claim.agents.failure_recovery.effectiveness"] ==
             ["agents.failure_recovery.effectiveness"]

    assert blockers["claim.rlm.provider_free_benchmark"] == ["rlm_benchmark.full"]

    refute Map.has_key?(blockers, "claim.evaluation.auto_evaluation.semantic_conformance")

    assert blockers["claim.evaluation.natural_judge.effectiveness"] == [
             "evaluation.natural_judge.effectiveness"
           ]

    assert blockers["claim.evaluation.refine_advice.effectiveness"] == [
             "evaluation.refine_advice.effectiveness"
           ]

    active_live_claim =
      Enum.find(
        dashboard["claims"]["claims"],
        &(&1["id"] == "claim.live_matched_model.full_parity")
      )

    assert active_live_claim["evidence_state"] == "missing"
    assert active_live_claim["claim_state"] == "target"
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
                   "latency" => %{"latency_ratio_imp_over_dspy" => 1.62},
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
      Enum.find(dashboard["profile_gate"]["checks"], &(&1["lane"] == "live_matched_model"))

    assert live_gate_check["blocking_requirements"] == live_blockers

    assert dashboard["lanes"]["live_matched_model"]["summary"]["imp_instrumentation"][
             "dominant_latency_source"
           ] == "provider_model"

    assert dashboard["lanes"]["live_matched_model"]["summary"]["imp_instrumentation"][
             "mean_lm_duration_share"
           ] == 0.98

    assert dashboard["lanes"]["live_matched_model"]["summary"]["runtime_shape"][
             "mean_message_chars_ratio_imp_over_dspy"
           ] == 1.05

    assert dashboard["lanes"]["live_matched_model"]["summary"]["runtime_shape"][
             "mean_raw_chars_ratio_imp_over_dspy"
           ] == 0.25

    assert dashboard["lanes"]["live_matched_model"]["summary"]["disagreements"][
             "pass_disagreements"
           ] == 2

    assert dashboard["lanes"]["live_matched_model"]["summary"]["disagreements"]["directions"][
             "imp_only_pass"
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
             "imp_only_or_deviation_optimizers"
           ] == [
             "BootstrapFinetune",
             "GRPO",
             "InstructionSearch"
           ]

    assert dashboard["lanes"]["gepa_replication"]["status"] == "failing"
    refute dashboard["lanes"]["gepa_replication"]["summary"]["full_gepa_replication"]
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_families"] == []
    assert dashboard["lanes"]["gepa_replication"]["summary"]["missing_fields"] != []

    assert dashboard["lanes"]["rag_tool_agent"]["status"] == "sample"

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Imp.Benchmark.Dashboard.run([
            "--profile",
            "telos",
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
            "--require-ready"
          ])
        end)
      end

    assert error.message =~ "profile readiness gate failed"
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
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
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
      {"future", :future, "stale", false},
      {"valid", :valid, "full", true}
    ]

    Enum.each(scenarios, fn {name, artifact_kind, expected_status, full_evidence} ->
      local_mlx_dir = Path.join(root, name)
      out_dir = Path.join(root, "#{name}-out")
      Enum.each([local_mlx_dir, out_dir], &File.mkdir_p!/1)

      case artifact_kind do
        :missing ->
          :ok

        :rejected ->
          write_local_mlx_artifact!(local_mlx_dir, status: "rejected")

        :tampered ->
          write_local_mlx_artifact!(local_mlx_dir, tampered: true)

        :stale ->
          write_local_mlx_artifact!(local_mlx_dir, generated_at: ~U[2000-01-01 00:00:00Z])

        :future ->
          write_local_mlx_artifact!(local_mlx_dir,
            generated_at: DateTime.add(DateTime.utc_now(), 3600, :second)
          )

        :valid ->
          write_local_mlx_artifact!(local_mlx_dir)
      end

      dashboard = run_local_mlx_dashboard!(local_mlx_dir, out_dir)
      lane = dashboard["lanes"]["local_mlx_weight_training"]

      assert lane["status"] == expected_status
      assert lane["full_evidence"] == full_evidence
      assert lane["passing"] == artifact_kind in [:stale, :future, :valid]

      if artifact_kind in [:rejected, :tampered] do
        assert [%{"kind" => "local_mlx_artifact_rejected"}] =
                 lane["blocking_requirements"]
      end
    end)
  end

  test "local MLX lane falls back from a newer rejected candidate" do
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

    assert lane["artifact"]["path"] == old_path
    assert lane["status"] == "full"
    assert lane["full_evidence"]
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

  test "RAG tool agent lane rejects a forged full summary without authoritative rows" do
    root = tmp_dir("dashboard-rag-tool-forgery")
    rag_dir = Path.join(root, "rag")
    out_dir = Path.join(root, "out")
    Enum.each([rag_dir, out_dir], &File.mkdir_p!/1)

    write_json!(Path.join(rag_dir, "rag-tool-agent-parity-forged.json"), %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "summary" => %{
        "total" => 15,
        "passing" => 15,
        "all_passing" => true,
        "provider_free_contract_complete" => true,
        "live_matched_behavior_complete" => true,
        "full_rag_tool_agent_parity" => true
      },
      "rows" => []
    })

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--rag-tool-agent-dir",
        rag_dir,
        "--out",
        out_dir
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    lane = path |> File.read!() |> Jason.decode!() |> get_in(["lanes", "rag_tool_agent"])

    assert lane["status"] == "failing"
    refute lane["full_evidence"]
    refute lane["summary"]["authority"]["rows_reconciled"]
    refute lane["summary"]["authority"]["full"]
  end

  test "missing mismatched failed or unpinned structural evidence stays red and blocks optimizer parity" do
    scenarios = [
      {"missing", :missing, "missing"},
      {"mismatched", [generated_at: "2020-01-01T00:00:00Z", git_sha: "stale-sha"], "failing"},
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
        Mix.Task.reenable("imp.benchmark.dashboard")

        Mix.Tasks.Imp.Benchmark.Dashboard.run([
          "--profile",
          "telos",
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
        Enum.find(
          dashboard["claims"]["claims"],
          &(&1["id"] == "claim.optimizer.bootstrap_few_shot.effectiveness")
        )

      assert optimizer_claim["evidence_state"] == "missing"
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
      "runner" => "imp-gepa-replication",
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
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
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

  test "require-ready fails when the public claims inventory is unreadable" do
    root = tmp_dir("dashboard-missing-claims")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Imp.Benchmark.Dashboard.run([
            "--out",
            out_dir,
            "--claims-file",
            Path.join(root, "missing-claims.json"),
            "--require-ready"
          ])
        end)
      end

    assert error.message =~ "claim claims_inventory"
    assert error.message =~ "machine-readable public claims inventory exists"
    assert error.message =~ "missing_claims_file"
  end

  test "alternate claims inventories are diagnostic and cannot authorize readiness" do
    root = tmp_dir("dashboard-alternate-claims")
    claims_path = Path.join(root, "claims.json")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    write_json!(claims_path, %{
      "schema_version" => 2,
      "claims" => [
        %{
          "id" => "claim.diagnostic.only",
          "claim_state" => "asserted",
          "target_rung" => "C0",
          "release" => "v0.1",
          "scope" => "Diagnostic inventory used only by this test.",
          "statement" => "A diagnostic claim cannot authorize release readiness.",
          "category" => "diagnostic",
          "surface" => ["dashboard"],
          "claim_type" => "diagnostic",
          "comparison" => "imp_native",
          "gate_policy" => "informational",
          "sources" => ["test/dashboard_test.exs"],
          "requirements" => [
            %{
              "id" => "diagnostic.missing",
              "kind" => "diagnostic",
              "lane" => "product_package",
              "evidence" => "full",
              "threshold" => "diagnostic only"
            }
          ]
        }
      ]
    })

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--claims-file",
        claims_path,
        "--out",
        out_dir
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()

    refute dashboard["profile_ready"]
    refute dashboard["claims"]["artifact"]["canonical"]
    assert dashboard["profile_gate"]["blocking_lanes"] == ["claims_inventory"]

    assert [%{"kind" => "noncanonical_claims_inventory"}] =
             dashboard["claims"]["blocking_requirements"]
  end

  test "claims inventory rejects duplicate claim and requirement ids" do
    root = tmp_dir("dashboard-duplicate-claims")
    claims_path = Path.join(root, "claims.json")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    canonical = "benchmarks/claims.json" |> File.read!() |> Jason.decode!()
    [first | rest] = canonical["claims"]
    write_json!(claims_path, put_in(canonical, ["claims"], [first, first | rest]))

    error =
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Task.reenable("imp.benchmark.dashboard")

          Mix.Tasks.Imp.Benchmark.Dashboard.run([
            "--claims-file",
            claims_path,
            "--out",
            out_dir,
            "--require-ready"
          ])
        end)
      end

    assert error.message =~ "invalid_claims_file"
  end

  test "require-ready failure summarizes campaign aggregate blockers" do
    root = tmp_dir("dashboard-campaign-blockers")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")

    Enum.each([results_dir, out_dir], &File.mkdir_p!/1)

    write_json!(Path.join(results_dir, "imp-dspy-parity-campaign-test-20260707T000000Z.json"), %{
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
          Mix.Tasks.Imp.Benchmark.Dashboard.run([
            "--profile",
            "telos",
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
            "--require-ready"
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
      Mix.Tasks.Imp.Benchmark.Dashboard.run([
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
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")
    Enum.each([live_matrix_dir, results_dir, out_dir], &File.mkdir_p!/1)

    write_json!(Path.join(live_matrix_dir, "live-matched-model-matrix-20260707T000000Z.json"), %{
      "schema_version" => 1,
      "generated_at" => "2026-07-07T00:00:00Z",
      "git_sha" => "abc",
      "summary" => %{
        "models" => 4,
        "full_parity_models" => 0,
        "matrix_complete" => false,
        "imp_instrumentation" => %{"complete" => true},
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
      Mix.Tasks.Imp.Benchmark.Dashboard.run([
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
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
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
             "protocol_gates",
             "rag_tool_agent"
           ]

    refute Enum.any?(dashboard["claims"]["claims"], &(&1["release"] == "telos"))

    assert_raise Mix.Error, ~r/unknown release profile/, fn ->
      Mix.Tasks.Imp.Benchmark.Dashboard.run(["--profile", "unknown", "--out", out_dir])
    end
  end

  test "immutable admitted C1 lanes are revalidated without expiring by age" do
    root = tmp_dir("dashboard-immutable-admission")
    out_dir = Path.join(root, "out")
    File.mkdir_p!(out_dir)

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--profile",
        "telos",
        "--out",
        out_dir,
        "--max-age-hours",
        "0"
      ])
    end)

    [path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = path |> File.read!() |> Jason.decode!()

    for lane_id <- ~w(
          auto_evaluation_contract
          bootstrap_few_shot_differential
          random_search_differential
          copro_isolation
          avatar_actor_differential
          avatar_optimizer_differential
          bootstrap_finetune_differential
          better_together_differential
          ensemble_differential
          mmgrpo_differential
        ) do
      lane = get_in(dashboard, ["lanes", lane_id])
      assert lane["status"] == "full"
      assert lane["passing"]
      assert lane["fresh"]
      assert lane["full_evidence"]
      assert lane["candidate_eligibility"]["policy"] == "immutable_admission"
      assert lane["candidate_eligibility"]["eligible"]
      assert lane["candidate_eligibility"]["validator_revalidated"]
      refute lane["candidate_eligibility"]["recency_valid"]
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
      "runner" => "imp-failure-campaign",
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

  test "failure recovery authority rejects a current-revision dirty workspace envelope" do
    root = tmp_dir("dashboard-failure-dirty-workspace")
    failure_dir = Path.join(root, "failure")
    out_dir = Path.join(root, "out")
    Enum.each([failure_dir, out_dir], &File.mkdir_p!/1)

    write_failure_campaign!(failure_dir, workspace_state: "dirty")
    dashboard = run_failure_dashboard!(root, "dirty-out", failure_dir)
    lane = dashboard["lanes"]["failure_recovery"]

    refute lane["passing"]
    refute lane["summary"]["authority"]["deterministic_complete"]
    refute lane["summary"]["authority"]["workspace_clean"]
  end

  test "current-git-bound deterministic evidence bypasses age but live evidence stays strict" do
    root = tmp_dir("dashboard-freshness-policy")
    gate_dir = Path.join(root, "gate")
    failure_dir = Path.join(root, "failure")
    overhead_dir = Path.join(root, "overhead")
    out_dir = Path.join(root, "out")
    Enum.each([gate_dir, failure_dir, overhead_dir, out_dir], &File.mkdir_p!/1)

    old = ~U[2000-01-01 00:00:00Z]
    current_sha = dashboard_git_sha()

    write_gate_evidence!(gate_dir, "product_package", "package.check",
      generated_at: old,
      git_sha: current_sha,
      name: "gate-evidence-product_package-current.json"
    )

    write_gate_evidence!(gate_dir, "product_package", "package.check",
      generated_at: DateTime.utc_now(),
      git_sha: "recent-wrong-sha",
      name: "gate-evidence-product_package-wrong.json"
    )

    write_gate_evidence!(gate_dir, "live_provider_smoke", "live.check",
      generated_at: old,
      git_sha: current_sha
    )

    write_failure_campaign!(failure_dir, generated_at: old, git_sha: current_sha)

    write_overhead_artifact!(overhead_dir, generated_at: old, git_sha: current_sha)

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--gate-dir",
        gate_dir,
        "--failure-campaign-dir",
        failure_dir,
        "--overhead-dir",
        overhead_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "1"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()

    deterministic_gate = dashboard["lanes"]["product_package"]
    assert deterministic_gate["status"] == "full"
    assert deterministic_gate["fresh"]
    assert deterministic_gate["artifact"]["git_sha"] == current_sha
    assert deterministic_gate["candidate_eligibility"]["source_compatible"]

    live_gate = dashboard["lanes"]["live_provider_smoke"]
    assert live_gate["status"] == "stale"
    refute live_gate["fresh"]
    refute live_gate["full_evidence"]

    failure_lane = dashboard["lanes"]["failure_recovery"]
    assert failure_lane["status"] == "passing"
    assert failure_lane["passing"]
    assert failure_lane["fresh"]

    overhead_lane = dashboard["lanes"]["provider_free_overhead"]
    assert overhead_lane["status"] == "full"
    assert overhead_lane["full_evidence"]
    assert dashboard["provider_free_overhead_regression_guard_passed"]
  end

  test "overhead authority requires a clean current-source run envelope" do
    root = tmp_dir("dashboard-overhead-workspace")
    overhead_dir = Path.join(root, "overhead")
    out_dir = Path.join(root, "out")
    Enum.each([overhead_dir, out_dir], &File.mkdir_p!/1)
    write_overhead_artifact!(overhead_dir, workspace_state: "dirty")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--overhead-dir",
        overhead_dir,
        "--out",
        out_dir
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))

    lane =
      dashboard_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["lanes", "provider_free_overhead"])

    refute lane["passing"]
    refute lane["full_evidence"]
    refute lane["candidate_eligibility"]["eligible"]
    assert "workspace_not_clean" in lane["candidate_eligibility"]["rejection_reasons"]
  end

  test "wrong-revision gate evidence is not selected as a lane artifact" do
    root = tmp_dir("dashboard-wrong-revision-only")
    gate_dir = Path.join(root, "gate")
    out_dir = Path.join(root, "out")
    Enum.each([gate_dir, out_dir], &File.mkdir_p!/1)

    write_gate_evidence!(gate_dir, "product_package", "package.check", git_sha: "wrong-revision")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--gate-dir",
        gate_dir,
        "--out",
        out_dir
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))

    lane =
      dashboard_path |> File.read!() |> Jason.decode!() |> get_in(["lanes", "product_package"])

    assert lane["status"] == "missing"
    assert lane["artifact"] == nil
    refute lane["candidate_eligibility"]["eligible"]
  end

  test "newer malformed gate evidence cannot mask an older valid candidate" do
    root = tmp_dir("dashboard-gate-validator-fallback")
    gate_dir = Path.join(root, "gate")
    out_dir = Path.join(root, "out")
    Enum.each([gate_dir, out_dir], &File.mkdir_p!/1)

    valid_path = Path.join(gate_dir, "gate-evidence-product_package-valid.json")

    write_gate_evidence!(gate_dir, "product_package", "package.check",
      generated_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_iso8601(),
      name: Path.basename(valid_path)
    )

    write_json!(Path.join(gate_dir, "gate-evidence-product_package-malformed.json"), %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "git_sha" => dashboard_git_sha(),
      "gate" => "different_gate",
      "summary" => %{"mix_task" => "package.check", "passing" => true}
    })

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--gate-dir",
        gate_dir,
        "--out",
        out_dir
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))

    lane =
      dashboard_path |> File.read!() |> Jason.decode!() |> get_in(["lanes", "product_package"])

    assert lane["status"] == "full"
    assert lane["artifact"]["path"] == valid_path
    assert lane["candidate_eligibility"]["eligible"]
  end

  test "failure recovery skips invalid tmp candidates and falls back to results" do
    root = tmp_dir("dashboard-failure-results-fallback")
    failure_dir = Path.join(root, "failure")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")
    Enum.each([failure_dir, results_dir, out_dir], &File.mkdir_p!/1)

    invalid_path = Path.join(failure_dir, "failure-campaign-newest.json")
    write_json!(invalid_path, %{"schema_version" => 3, "runner" => "imp-failure-campaign"})
    File.touch!(invalid_path, {{2099, 1, 1}, {0, 0, 0}})

    valid_path =
      write_failure_campaign!(results_dir,
        generated_at: ~U[2000-01-01 00:00:00Z],
        git_sha: dashboard_git_sha()
      )

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--failure-campaign-dir",
        failure_dir,
        "--results-dir",
        results_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "1"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()
    lane = dashboard["lanes"]["failure_recovery"]

    assert lane["artifact"]["path"] == valid_path
    assert lane["passing"]
    assert lane["fresh"]
  end

  test "failure recovery prefers admitted live evidence over newer deterministic evidence" do
    root = tmp_dir("dashboard-failure-live-preference")
    failure_dir = Path.join(root, "failure")
    results_dir = Path.join(root, "results")
    out_dir = Path.join(root, "out")
    Enum.each([failure_dir, results_dir, out_dir], &File.mkdir_p!/1)

    current_sha = dashboard_git_sha()

    deterministic_path =
      write_failure_campaign!(failure_dir,
        generated_at: DateTime.utc_now(),
        git_sha: current_sha
      )

    live_path =
      write_failure_campaign!(results_dir,
        generated_at: DateTime.utc_now(),
        git_sha: current_sha,
        live: true,
        reported_release_complete: true
      )

    File.touch!(live_path, {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(deterministic_path, {{2099, 1, 1}, {0, 0, 0}})

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--failure-campaign-dir",
        failure_dir,
        "--results-dir",
        results_dir,
        "--out",
        out_dir,
        "--max-age-hours",
        "1"
      ])
    end)

    [dashboard_path] = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))

    lane =
      dashboard_path |> File.read!() |> Jason.decode!() |> get_in(["lanes", "failure_recovery"])

    assert lane["artifact"]["path"] == live_path
    assert lane["status"] == "full"
    assert lane["full_evidence"]
  end

  # The timestamp slug is second-granular, so two runs inside one wall-clock
  # second used to write the SAME filename and the second silently overwrote
  # the first (the ambiguity behind the CI race fixed in PR #14 on the reader
  # side). The task must allocate exclusively: every run yields its own file.
  # Sentinels pre-planted at every slug the runs could pick force the collision
  # deterministically instead of hoping both runs land in one second.
  @tag :evidence_infrastructure
  test "back-to-back runs into one out dir write two distinct dashboard files" do
    root = tmp_dir("dashboard-no-clobber")
    out_dir = Path.join(root, "out")
    results_dir = Path.join(root, "results")
    Enum.each([out_dir, results_dir], &File.mkdir_p!/1)

    sentinel_payload = ~s({"sentinel":true})
    start = DateTime.truncate(DateTime.utc_now(), :second)

    sentinels =
      for offset <- 0..30 do
        slug =
          start
          |> DateTime.add(offset)
          |> DateTime.to_iso8601()
          |> String.replace(~r/[^0-9A-Za-z]/, "")

        path = Path.join(out_dir, "parity-dashboard-#{slug}.json")
        File.write!(path, sentinel_payload)
        path
      end

    announced =
      Enum.map(1..2, fn _run ->
        output =
          capture_io(fn ->
            Mix.Task.reenable("imp.benchmark.dashboard")

            Mix.Tasks.Imp.Benchmark.Dashboard.run([
              "--results-dir",
              results_dir,
              "--out",
              out_dir
            ])
          end)

        case Regex.run(~r/parity dashboard: (\S+)/, output) do
          [_line, path] -> path
          nil -> flunk("dashboard task did not announce its output path: #{inspect(output)}")
        end
      end)

    assert [first, second] = announced
    refute first == second, "second run reused the first run's path: #{first}"

    for path <- sentinels do
      assert File.read!(path) == sentinel_payload,
             "dashboard run clobbered a pre-existing artifact: #{path}"
    end

    written = Path.wildcard(Path.join(out_dir, "parity-dashboard-*.json"))
    assert Enum.sort(written) == Enum.sort(sentinels ++ announced)

    for path <- announced do
      assert %{"profile_ready" => _} = path |> File.read!() |> Jason.decode!()
    end
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true))

  defp write_overhead_artifact!(dir, opts \\ []) do
    budgets = Imp.BenchmarkTruth.OverheadPolicy.budgets()

    cases =
      Enum.map(budgets, fn {id, _budget} ->
        Imp.BenchmarkTruth.OverheadPolicy.evaluate!(
          id,
          %{"median_us" => 1.0},
          %{"median_us" => 2.0}
        )
      end)

    clock = fn -> Keyword.get(opts, :generated_at, DateTime.utc_now()) end
    source_sha = Keyword.get(opts, :git_sha, dashboard_git_sha())

    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@#{source_sha}"},
        workspace_state: Keyword.get(opts, :workspace_state, "clean"),
        inputs: %{
          "protocol_id" => "provider_free_overhead_regression_guard_v2",
          "policy" => budgets
        },
        clock: clock
      )

    artifact = %{
      "schema_version" => 2,
      "runner" => "imp-dspy-overhead-regression-guard",
      "policy" => %{
        "id" => "named_per_operation_v1",
        "ratios_are_measurements_not_speed_claims" => true,
        "budgets" => budgets
      },
      "summary" => %{
        "total" => length(cases),
        "passing" => length(cases),
        "all_passing" => true
      },
      "imp" => %{"environment" => context.environment},
      "dspy" => %{
        "runner" => "python-dspy-overhead",
        "dspy_version" => Imp.BenchmarkTruth.OverheadPolicy.dspy_version(),
        "environment" => %{
          "system" => "test-system",
          "release" => "test-release",
          "machine" => "test-machine",
          "python_implementation" => "CPython",
          "python_executable" => "/test/python",
          "script_sha256" => Imp.BenchmarkTruth.OverheadPolicy.script_sha256()
        }
      },
      "cases" => cases
    }

    path = Path.join(dir, "overhead-parity-test.json")

    %{path: written_path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, context)

    written_path
  end

  defp run_failure_dashboard!(root, out_name, failure_dir) do
    out_dir = Path.join(root, out_name)
    results_dir = Path.join(root, "#{out_name}-results")
    File.mkdir_p!(out_dir)
    File.mkdir_p!(results_dir)

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.dashboard")

      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--failure-campaign-dir",
        failure_dir,
        "--results-dir",
        results_dir,
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
      "runner" => "imp-failure-campaign",
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

    clock = fn -> Keyword.get(opts, :generated_at, ~U[2026-07-07 00:02:00Z]) end
    source_sha = Keyword.get(opts, :git_sha, dashboard_git_sha())

    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@#{source_sha}"},
        workspace_state: Keyword.get(opts, :workspace_state, "clean"),
        clock: clock
      )

    path = Path.join(dir, "failure-campaign-test.json")

    %{path: written_path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, context)

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
      "provider" => "local_injected_transport",
      "model" => "local-fixture",
      "attempts" => 2,
      "max_attempts" => 2,
      "injected_timeout" => true,
      "timeout_reason" => "timeout",
      "terminal_status" => 200,
      "idempotency_header_stable" => true,
      "attempt_timeout_ms" => 25,
      "deadline_ms" => 200,
      "elapsed_ms" => 25,
      "canary_sha256" => "sha256:dummy",
      "canary_included" => false
    }

  defp failure_live_evidence("retrieval_and_tool_agent_recovery_live"),
    do: %{
      "provider" => "local_static_lm",
      "model" => "local-fixture",
      "retrieval_attempts" => 2,
      "retrieval_injected_error" => "closed",
      "retrieval_terminal_network" => "local_injected_transport",
      "tool_attempts" => 2,
      "tool_failures" => 1,
      "tool_successes" => 1,
      "submit_calls" => 1,
      "deadline_ms" => 1_000,
      "elapsed_ms" => 10,
      "canary_sha256" => "sha256:dummy",
      "canary_included" => false,
      "history" => [
        %{"tool" => "lookup", "result" => "transient_local_failure"},
        %{"tool" => "lookup", "result" => "pong"},
        %{"tool" => "submit", "result" => "completed"}
      ]
    }

  defp failure_live_checks("provider_retry_timeout_idempotency_live") do
    Enum.map(
      ~w(repeated_zero_flakes runtime_leak_free local_provider_terminal_success bounded_injected_timeout stable_idempotency_key dummy_canary_absent),
      &%{"id" => &1, "passing" => true}
    )
  end

  defp failure_live_checks("retrieval_and_tool_agent_recovery_live") do
    Enum.map(
      ~w(repeated_zero_flakes runtime_leak_free live_retrieval_recovered recoverable_tool_failure_retry_submit),
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

  defp source_bound_rag_tool_agent_artifact do
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    revision = String.trim(revision)

    source = %{
      "repository" => "stanfordnlp/dspy",
      "version" => "3.2.1",
      "commit" => "29448ae12756abdd14bd8796c819247ebb83673c",
      "script_sha256" => sha256_file("scripts/dspy_rag_tool_agent.py"),
      "authority_sha256" => sha256_file("benchmarks/authority_sources/dspy-3.2.1-29448ae.json"),
      "fixture_sha256" =>
        sha256_file("test/fixtures/benchmarks/rag-tool-agent-provider-free.json")
    }

    rows = rag_tool_agent_rows()

    artifact = %{
      "schema_version" => 1,
      "summary" => %{
        "total" => length(rows),
        "passing" => length(rows),
        "all_passing" => true,
        "direct_comparisons" => 4,
        "imp_only_or_deviation" => 12,
        "provider_free_contract_complete" => true,
        "bounded_provider_free_operational_contracts_complete" => true,
        "live_matched_behavior_complete" => true,
        "full_rag_tool_agent_parity" => true,
        "comparative_effectiveness_complete" => false
      },
      "dspy" => %{"source" => source},
      "rows" => rows
    }

    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{
          "imp" => "deepfates/imp@#{revision}",
          "dspy" => "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"
        },
        workspace_state: "clean",
        inputs: Mix.Tasks.Imp.Benchmark.RagToolAgent.source_bindings()
      )

    Imp.BenchmarkTruth.RunContext.finish(context, artifact)
  end

  defp sha256_file(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end

  defp rag_tool_agent_rows do
    provider_free_ids = ~w(
      rag_memory_retrieval
      rag_multi_hop_retrieval
      http_retriever_protocol_shape
      react_lookup_tool
      react_unknown_tool_error_trace
      mcp_import_agent_trace
      agent_tool_policy_denial
      react_v2_recovers_from_tool_and_submit_errors
      code_act_tool_program
      program_of_thought_safe_eval
      program_of_thought_rejects_unsafe_remote_call
      streaming_incremental_fields
      tasks_async_stream_ordered_results
      save_load_redacts_provider_secret
    )

    base_evidence = %{
      "mode" => "live",
      "provider" => "anthropic",
      "model_identity" => "claude-haiku-4-5-20251001",
      "generation" => %{"max_tokens" => 400},
      "usage_complete" => true,
      "error" => nil
    }

    live_row = fn id, prompt_contract, imp_termination, dspy_termination ->
      %{
        "id" => id,
        "passing" => true,
        "imp" => %{
          "passing" => true,
          "evidence" =>
            Map.merge(base_evidence, %{
              "wire_api" => "anthropic_messages",
              "prompt_contract" => prompt_contract,
              "termination_tool" => imp_termination
            })
        },
        "dspy" => %{
          "passing" => true,
          "evidence" =>
            Map.merge(base_evidence, %{
              "wire_api" => "litellm_anthropic_messages",
              "prompt_contract" => prompt_contract,
              "termination_tool" => dspy_termination
            })
        }
      }
    end

    Enum.map(provider_free_ids, &%{"id" => &1, "passing" => true}) ++
      [
        live_row.("live_rag_memory_retrieval", "rag-exact-context-v1", nil, nil),
        live_row.(
          "live_mcp_lookup_tool",
          "lookup-capital-then-terminate-v1",
          "submit",
          "finish"
        )
      ]
  end

  defp run_instruction_optimizer_dashboard!(contract_dir, out_dir) do
    run_dashboard_and_read_output!([
      "--instruction-optimizer-dir",
      contract_dir,
      "--out",
      out_dir,
      "--max-age-hours",
      "1"
    ])
  end

  defp run_local_mlx_dashboard!(local_mlx_dir, out_dir) do
    run_dashboard_and_read_output!([
      "--local-mlx-dir",
      local_mlx_dir,
      "--out",
      out_dir,
      "--max-age-hours",
      "100000"
    ])
  end

  # Read exactly the file THIS run announced. Selecting "the newest
  # parity-dashboard-*.json by mtime" is ambiguous when two runs in one test
  # land in adjacent wall-clock seconds: File.stat! mtimes are second-granular,
  # and an mtime tie resolves to the alphabetically first (oldest) slug, so the
  # reader silently returns the PREVIOUS run's dashboard (CI-only failure of
  # "instruction optimizer full evidence requires the dashboard code revision",
  # run 29622004461).
  defp run_dashboard_and_read_output!(args) do
    output =
      capture_io(fn ->
        Mix.Task.reenable("imp.benchmark.dashboard")
        Mix.Tasks.Imp.Benchmark.Dashboard.run(args)
      end)

    case Regex.run(~r/parity dashboard: (\S+)/, output) do
      [_line, path] ->
        path |> File.read!() |> Jason.decode!()

      nil ->
        flunk("dashboard task did not announce its output path; captured: #{inspect(output)}")
    end
  end

  defp write_local_mlx_artifact!(dir, opts \\ []) do
    artifact = @local_mlx_fixture |> File.read!() |> Jason.decode!()
    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])
    payload = if status = opts[:status], do: Map.put(payload, "status", status), else: payload
    clock = fn -> Keyword.get(opts, :generated_at, DateTime.utc_now()) end

    artifact =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@dashboard-test"},
        workspace_state: "clean",
        clock: clock
      )
      |> Imp.BenchmarkTruth.RunContext.finish(payload)

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

  defp write_gate_evidence!(dir, gate, mix_task, opts \\ []) do
    name = Keyword.get(opts, :name, "gate-evidence-#{gate}-20260707T000000Z.json")

    write_json!(Path.join(dir, name), %{
      "schema_version" => 1,
      "runner" => "imp-gate-evidence",
      "generated_at" => Keyword.get(opts, :generated_at, "2026-07-07T00:00:00Z"),
      "git_sha" => Keyword.get(opts, :git_sha, dashboard_git_sha()),
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
        "prompt_contract" => %{"imp_req_llm" => if(prompt_current?, do: "v7", else: "v6")},
        "expected_prompt_contract" => %{"imp_req_llm" => "v7"},
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
        "imp_instrumentation" => %{"complete" => true},
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
            "imp_gepa" => 150,
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
            "imp" => "deepfates/imp@abcdef2",
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
            "baseline" => %{"score" => 0.5, "source" => "Imp baseline runner artifact"},
            "dspy_gepa" => %{"score" => 0.6, "source" => "DSPy GEPA runner artifact"},
            "imp_gepa" => %{"score" => 0.61, "source" => "Imp GEPA runner artifact"},
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
              "Imp ChainOfThought JudgeQuality source-faithful pairwise order check",
            "leakage_judge" =>
              "Imp ChainOfThought JudgeLeakage source-faithful pii leaked-count check",
            "score_formula" => "(quality + (1 - leakage)) / 2.0"
          })
        else
          row
        end
      end
    )
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
