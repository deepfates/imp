defmodule MatchedInstructionOptimizersTRECExampleTest do
  use ExUnit.Case, async: true

  Code.require_file(
    "contract.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "two_phase.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "response_evidence.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "source_identity.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "call_budget.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  Code.require_file(
    "aggregate.exs",
    Path.expand("../examples/matched_instruction_optimizers_trec", __DIR__)
  )

  alias MatchedInstructionOptimizersTREC.Contract
  alias MatchedInstructionOptimizersTREC.TwoPhase
  alias MatchedInstructionOptimizersTREC.SourceIdentity
  alias MatchedInstructionOptimizersTREC.CallBudget
  alias MatchedInstructionOptimizersTREC.Aggregator

  @manifest "examples/matched_instruction_optimizers_trec/contract.json"
  @result "benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json"
  @recomputation_root "benchmarks/evidence/archive/matched_experiments/trec"

  test "freezes exact authorities, dataset IDs, models, and runtime request controls" do
    manifest = Contract.load!(@manifest)

    assert manifest["seeds"] == [2_026_072_602, 2_026_072_603, 2_026_072_604]
    assert get_in(manifest, ["authorities", "dspy", "version"]) == "3.2.1"

    assert get_in(manifest, ["authorities", "dspy", "commit"]) ==
             "29448ae12756abdd14bd8796c819247ebb83673c"

    assert manifest["arms"] == ~w(baseline gepa mipro_v2)
    assert length(manifest["dataset"]["splits"]["train_ids"]) == 20
    assert length(manifest["dataset"]["splits"]["selection_ids"]) == 40
    assert length(manifest["dataset"]["splits"]["held_out_ids"]) == 80

    assert manifest["models"]["task"]["logical"] == "openai/gpt-5.4-mini"
    assert manifest["models"]["optimizer"]["logical"] == "anthropic/claude-sonnet-4.6"
    assert get_in(manifest, ["execution", "request", "task", "seed"]) == "experiment_seed"

    assert manifest["launch_status"] == "sealed"

    assert get_in(manifest, ["runtime_dependencies", "upstream", "packages", "optuna"]) ==
             "4.9.0"

    assert manifest["execution"]
           |> Map.take(~w(concurrency cache retry max_retries json_fallback fallbacks)) == %{
             "concurrency" => 1,
             "cache" => false,
             "retry" => false,
             "max_retries" => 0,
             "json_fallback" => false,
             "fallbacks" => false
           }
  end

  test "strict parser accepts only the matched ChatAdapter marker envelope" do
    assert {:ok, "K11"} =
             Contract.parse_route("[[ ## route ## ]]\nK11\n\n[[ ## completed ## ]]\n")

    assert {:ok, "K47"} = Contract.parse_route(%{"route" => "K47"})
    assert {:error, :invalid_exact_chat_marker_envelope} = Contract.parse_route("K11")

    assert {:error, :invalid_exact_chat_marker_envelope} =
             Contract.parse_route("[[ ## route ## ]]\nK99\n\n[[ ## completed ## ]]\n")

    assert {:error, :invalid_exact_route_envelope} =
             Contract.parse_route(%{"route" => "K11", "reason" => "extra"})

    assert {:error, :invalid_exact_route_envelope} =
             Contract.parse_route([%{"route" => "K11"}])
  end

  test "dry plan computes the exact matched worst-case envelope without execution" do
    plan = Contract.plan!(@manifest)

    assert plan["network_calls"] == 0
    assert plan["models_started"] == 0
    assert plan["downloads"] == 0

    assert plan["per_seed_per_runtime"] == %{
             "baseline" => %{"task_calls" => 120, "optimizer_calls" => 0, "total_calls" => 120},
             "gepa" => %{"task_calls" => 450, "optimizer_calls" => 48, "total_calls" => 498},
             "mipro_v2" => %{"task_calls" => 620, "optimizer_calls" => 9, "total_calls" => 629}
           }

    assert Map.delete(plan["worst_case"], "usd") == %{
             "task_calls" => 7_140,
             "optimizer_calls" => 342,
             "total_calls" => 7_482,
             "input_tokens" => 34_848_768,
             "output_tokens" => 2_178_048
           }

    assert_in_delta plan["worst_case"]["usd"], 59.10912, 1.0e-12

    assert plan["gepa_stopping"] == %{
             "semantic_max_metric_calls" => 280,
             "legal_iteration_metric_call_cap" => 330,
             "legal_reflection_transport_cap" => 48,
             "maximum_started_iterations" => 24,
             "outer_complete_task_transport_cap" => 450,
             "rule" =>
               "check semantic max between iterations; every legally started iteration completes"
           }

    assert get_in(plan, ["runtime_configs", "imp", "adapter_rendering"]) ==
             "byte_identical_baseline_and_frozen_injected_instruction_probe; live candidate instructions must be rendered; optimizer trajectories may diverge"

    assert get_in(plan, ["runtime_configs", "upstream", "capture", "rendered_messages"])

    assert get_in(plan, ["runtime_configs", "imp", "arm_call_ceilings"]) ==
             get_in(plan, ["runtime_configs", "upstream", "arm_call_ceilings"])
  end

  test "Elixir and Python derive the same pinned legal-iteration envelope" do
    script = "examples/matched_instruction_optimizers_trec/gepa_budget_envelope.py"
    assert {output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)

    assert Jason.decode!(output) == %{
             "max_metric_calls" => 330,
             "max_reflection_calls" => 48,
             "max_iterations" => 24
           }

    assert Imp.Optimizer.GEPA.v014_budget_envelope(40, 10, 280) == %{
             max_metric_calls: 330,
             max_reflection_calls: 48,
             max_iterations: 24
           }
  end

  test "role-aware budget refuses before a dispatch can exceed any ceiling" do
    ceiling = %{
      "task_logical" => 1,
      "optimizer_logical" => 1,
      "total_logical" => 2,
      "transports" => 2
    }

    counts = CallBudget.zero() |> CallBudget.reserve!(ceiling, :task)

    assert counts == %{
             "task_logical" => 1,
             "optimizer_logical" => 0,
             "total_logical" => 1,
             "transports" => 1
           }

    assert_raise RuntimeError, ~r/refused task before dispatch/, fn ->
      CallBudget.reserve!(counts, ceiling, :task)
    end

    assert CallBudget.reserve!(counts, ceiling, :optimizer)["total_logical"] == 2
  end

  test "MIPRO uses its source-correct public num_candidates option" do
    optimizer =
      Imp.Optimizer.MIPROv2.new(fn _example, _prediction -> 0.0 end,
        auto: nil,
        num_candidates: 2,
        num_trials: 1
      )

    assert optimizer.config.num_candidates == 2

    assert_raise ArgumentError, ~r/unknown MIPROv2 options/, fn ->
      Imp.Optimizer.MIPROv2.new(fn _example, _prediction -> 0.0 end,
        num_instruct_candidates: 2
      )
    end
  end

  test "upstream no-model boundary regressions pass" do
    script =
      Path.expand("../examples/matched_instruction_optimizers_trec/no_model_test.py", __DIR__)

    assert {output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)
    assert output =~ "Ran 11 tests"
  end

  test "strong runners retain launch, seed, input, USD, endpoint, tier, and dual-cost guards" do
    imp = File.read!("examples/matched_instruction_optimizers_trec/run_imp.exs")
    upstream = File.read!("examples/matched_instruction_optimizers_trec/run_upstream.py")

    for source <- [imp, upstream] do
      assert source =~ "launch_status"
      assert source =~ "max_input_tokens"
      assert source =~ "usd_reserved"
      assert source =~ "/endpoints"
      assert source =~ "service_tier"
      assert source =~ "gateway_reported_cost"
      assert source =~ "computed_cost"
    end

    assert imp =~ "Keyword.put(opts, :seed, seed)"
    assert imp =~ "execution_profile: :gepa_v0_1_4"
    assert imp =~ "search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup"
    assert imp =~ "Imp.OperationalSafetyError"
    assert imp =~ "verify_runtime_dependencies!"
    assert upstream =~ "seed=seed"
    assert upstream =~ "verify_runtime_dependencies(manifest)"
    assert upstream =~ "materialized upstream environment differs from committed lock"

    {verify_offset, _} = :binary.match(upstream, "verify_runtime_dependencies(manifest)")
    {install_offset, _} = :binary.match(upstream, "dspy, RecordingLM = install_runtime(args)")
    assert verify_offset < install_offset
  end

  test "the live wrapper canary is independently capped at one call per production role" do
    runner = File.read!("examples/matched_instruction_optimizers_trec/run_imp.exs")
    canary = File.read!("examples/matched_instruction_optimizers_trec/run_wrapper_canary.exs")

    assert runner =~ "System.get_env(\"IMP_MATCHED_TREC_LOAD_ONLY\") == \"1\""
    assert canary =~ ~s(@arm "wrapper_canary_014a7fc")
    assert canary =~ ~s("task_logical" => 1)
    assert canary =~ ~s("optimizer_logical" => 1)
    assert canary =~ ~s("total_logical" => 2)
    assert canary =~ ~s("transports" => 2)
    assert canary =~ "ObservedLM"
    assert runner =~ "ResponseEvidence.validate_contract"
    assert canary =~ "scientific_treatment: false"
    assert {:ok, _ast} = Code.string_to_quoted(canary)
  end

  test "production runner guards remain cross-runtime equivalent" do
    script = "examples/matched_instruction_optimizers_trec/guard_equivalence.py"
    assert {output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)
    report = Jason.decode!(output)
    assert report["status"] == "pass"
    assert report["count"] == 14
    assert Enum.count(report["guards"], &(&1["comparison"] == "identical")) == 10
    assert Enum.count(report["guards"], &(&1["comparison"] == "intentional_difference")) == 4
    assert Enum.all?(report["guards"], &(is_binary(&1["rationale"]) and &1["rationale"] != ""))

    assert Enum.map(report["guards"], & &1["guard"]) == [
             "launch",
             "predispatch_reservation",
             "model_identity",
             "route_identity",
             "request_seed",
             "token_limits",
             "cost",
             "finish_content_envelope",
             "task_parser",
             "optimizer_parser",
             "retry_fallback",
             "call_ceiling",
             "heldout_barrier",
             "stop_persistence"
           ]
  end

  test "paired coordinator refuses authority until both runtime preflights pass" do
    script = "examples/matched_instruction_optimizers_trec/paired_coordinator_test.py"
    assert {output, 0} = System.cmd("python3", [script], stderr_to_stdout: true)
    assert output =~ "Ran 6 tests"

    coordinator = File.read!("examples/matched_instruction_optimizers_trec/run_paired.py")
    assert coordinator =~ ~S|env.pop("OPENROUTER_API_KEY", None)|
    assert coordinator =~ ~s(cwd=HERE)
    assert coordinator =~ ~S|PRIOR_SPEND_BOUND = Decimal("3.08335175")|
    assert coordinator =~ ~S|WORKSHOP_CEILING = Decimal("100.00")|
    assert coordinator =~ "stdin=subprocess.DEVNULL"
    assert coordinator =~ "require_rescued_stop_artifacts()"
    assert coordinator =~ "imp = preflight_imp(manifest_sha)"
    assert coordinator =~ "upstream = preflight_upstream(manifest)"
    assert coordinator =~ "return 0 if preflight_only else run_peers()"

    imp_runner = File.read!("examples/matched_instruction_optimizers_trec/run_imp.exs")
    upstream_runner = File.read!("examples/matched_instruction_optimizers_trec/run_upstream.py")
    assert imp_runner =~ "System.trap_signal(:sigterm"
    assert imp_runner =~ "stopped_payload(observer, source_commits"
    assert upstream_runner =~ "signal.signal(signal.SIGTERM, coordinated_stop)"
  end

  test "completed matched outcome keeps its exact task-specific claim boundary" do
    result = @result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"
    assert result["manifest"]["sha256"] == Contract.load!(@manifest)["manifest_sha256"]
    assert result["dataset"]["test_visible_to_optimization_or_selection"] == false
    assert result["paired_acceptance"]["headline_passed"]
    assert result["paired_acceptance"]["winning_optimizer"] == "gepa"

    assert get_in(result, ["paired_acceptance", "imp_gepa_minus_imp_baseline", "mean"]) ==
             0.4

    assert get_in(
             result,
             ["paired_acceptance", "imp_gepa_minus_upstream_gepa", "confidence_interval_95"]
           ) == [-0.04583333333333334, 0.029166666666666667]

    assert get_in(
             result,
             ["paired_acceptance", "imp_gepa_minus_upstream_gepa", "noninferiority_passed"]
           )

    assert result["execution"]["treatment_cost_usd"] == 3.13862325
    assert "BEAM-native superiority" in result["claim_boundary"]["excludes"]

    assert Enum.any?(
             result["claim_boundary"]["excludes"],
             &String.starts_with?(&1, "SIMBA, COPRO, InferRules")
           )
  end

  test "committed compact scored rows independently recompute the matched outcome" do
    receipt =
      @recomputation_root
      |> Path.join("recomputation.json")
      |> File.read!()
      |> Jason.decode!()

    imp_path = Path.join(@recomputation_root, "imp-scored-rows.json")
    upstream_path = Path.join(@recomputation_root, "upstream-scored-rows.json")
    aggregate_path = Path.join(@recomputation_root, "aggregate-recomputed.json")

    assert_file_receipt!(imp_path, receipt["inputs"]["imp"])
    assert_file_receipt!(upstream_path, receipt["inputs"]["upstream"])
    assert_file_receipt!(aggregate_path, receipt["aggregate"])
    assert_file_receipt!(@result, receipt["source_outcome"])

    aggregate = Aggregator.aggregate!(@manifest, imp_path, upstream_path)
    assert aggregate == aggregate_path |> File.read!() |> Jason.decode!()

    outcome = @result |> File.read!() |> Jason.decode!()

    for runtime <- ~w(imp upstream) do
      assert Map.take(receipt["raw_sources"][runtime], ~w(bytes sha256)) ==
               Map.take(outcome["raw_retained_artifacts"][runtime], ~w(bytes sha256))
    end

    assert Map.take(receipt["raw_sources"]["aggregate"], ~w(bytes sha256)) ==
             Map.take(outcome["raw_retained_artifacts"]["aggregate"], ~w(bytes sha256))

    assert get_in(aggregate, ["acceptance", "winning_optimizer"]) ==
             outcome["paired_acceptance"]["winning_optimizer"]

    assert get_in(aggregate, ["acceptance", "improvements", "gepa", "mean"]) ==
             get_in(outcome, ["paired_acceptance", "imp_gepa_minus_imp_baseline", "mean"])

    assert get_in(aggregate, ["acceptance", "improvements", "mipro_v2", "mean"]) ==
             get_in(outcome, ["paired_acceptance", "imp_mipro_v2_minus_imp_baseline", "mean"])

    assert get_in(
             aggregate,
             ["acceptance", "winning_optimizer_imp_minus_upstream", "confidence_interval"]
           ) ==
             get_in(
               outcome,
               ["paired_acceptance", "imp_gepa_minus_upstream_gepa", "confidence_interval_95"]
             )
  end

  test "compact recomputation rejects a consistently falsified gold label" do
    root = Path.join(System.tmp_dir!(), "imp-trec-compact-gold-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    imp =
      @recomputation_root
      |> Path.join("imp-scored-rows.json")
      |> File.read!()
      |> Jason.decode!()

    altered =
      update_in(imp, ["seeds", Access.at(0), "arms", Access.at(0), "rows", "held_out"], fn
        [row | rest] ->
          expected = if row["expected"] == "K11", do: "K47", else: "K11"
          [%{row | "expected" => expected, "correct" => expected == row["parsed_route"]} | rest]
      end)

    imp_path = Path.join(root, "imp.json")
    File.write!(imp_path, Jason.encode!(altered))

    upstream_path = Path.join(@recomputation_root, "upstream-scored-rows.json")

    assert_raise ArgumentError, ~r/result row score fields are inconsistent/, fn ->
      Aggregator.aggregate!(@manifest, imp_path, upstream_path)
    end
  end

  test "shared aggregator recomputes three-seed rows and labels uncertainty honestly" do
    manifest = Contract.load!(@manifest)

    root =
      Path.join(System.tmp_dir!(), "imp-matched-aggregate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    selection = perfect_rows("examples/matched_instruction_optimizers_trec/selection.jsonl")
    held_out = perfect_rows("examples/matched_instruction_optimizers_trec/held_out.jsonl")

    summary = fn rows ->
      %{"accuracy" => 1.0, "macro_f1" => 1.0, "parse_errors" => 0, "count" => length(rows)}
    end

    result = fn runtime ->
      %{
        "schema_version" => 3,
        "runtime" => runtime,
        "status" => "complete",
        "manifest_sha256" => manifest["manifest_sha256"],
        "source_commits" => %{"imp" => "i", "dspy" => "d", "gepa" => "g"},
        "seeds" =>
          Enum.map(manifest["seeds"], fn seed ->
            %{
              "seed" => seed,
              "arms" =>
                Enum.map(~w(baseline gepa mipro_v2), fn arm ->
                  %{
                    "arm" => arm,
                    "selection" => summary.(selection),
                    "held_out" => summary.(held_out),
                    "rows" => %{"selection" => selection, "held_out" => held_out}
                  }
                end)
            }
          end)
      }
    end

    imp_path = Path.join(root, "imp.json")
    upstream_path = Path.join(root, "upstream.json")
    File.write!(imp_path, Jason.encode!(result.("imp")))
    File.write!(upstream_path, Jason.encode!(result.("upstream")))

    aggregate = Aggregator.aggregate!(@manifest, imp_path, upstream_path)

    assert get_in(aggregate, ["within_runtime", "imp", "gepa", "held_out", "accuracy"]) == %{
             "paired_deltas" => [0.0, 0.0, 0.0],
             "mean" => 0.0,
             "exact_observed_range" => [0.0, 0.0]
           }

    assert aggregate["uncertainty"]["method"] == "source_id_cluster_bootstrap_all_three_seeds"

    legacy_typed_nil = %{"__imp_type__" => "atom", "value" => "nil"}

    legacy_imp_projection =
      result.("imp")
      |> update_in(["seeds"], fn seeds ->
        Enum.map(seeds, fn seed ->
          update_in(seed, ["arms"], fn arms ->
            Enum.map(arms, fn arm ->
              Enum.reduce(~w(selection held_out), arm, fn split, arm ->
                rows = get_in(arm, ["rows", split])

                arm
                |> put_in(
                  ["rows", split],
                  Enum.map(rows, &Map.put(&1, "error", legacy_typed_nil))
                )
                |> put_in([split, "parse_errors"], length(rows))
              end)
            end)
          end)
        end)
      end)

    File.write!(imp_path, Jason.encode!(legacy_imp_projection))
    legacy_aggregate = Aggregator.aggregate!(@manifest, imp_path, upstream_path)

    assert get_in(
             legacy_aggregate,
             ["metrics", "imp", "2026072602", "baseline", "held_out", "parse_errors"]
           ) == 0

    losing_baseline_rows =
      Enum.map(held_out, fn row ->
        %{row | "parsed_route" => nil, "correct" => false, "error" => "synthetic_miss"}
      end)

    imp_with_winner =
      result.("imp")
      |> update_in(["seeds"], fn seeds ->
        Enum.map(seeds, fn seed ->
          update_in(seed, ["arms"], fn arms ->
            Enum.map(arms, fn
              %{"arm" => "baseline"} = arm ->
                arm
                |> put_in(["held_out"], %{
                  "accuracy" => 0.0,
                  "macro_f1" => 0.0,
                  "parse_errors" => length(losing_baseline_rows),
                  "count" => length(losing_baseline_rows)
                })
                |> put_in(["rows", "held_out"], losing_baseline_rows)

              arm ->
                arm
            end)
          end)
        end)
      end)

    File.write!(imp_path, Jason.encode!(imp_with_winner))
    winning_aggregate = Aggregator.aggregate!(@manifest, imp_path, upstream_path)
    assert winning_aggregate["acceptance"]["headline_passed"]
    assert winning_aggregate["acceptance"]["winning_optimizer"] in ~w(gepa mipro_v2)

    tampered =
      put_in(
        result.("upstream"),
        ["seeds", Access.at(0), "arms", Access.at(0), "held_out", "accuracy"],
        0.5
      )

    File.write!(upstream_path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/held_out summary does not match scored rows/, fn ->
      Aggregator.aggregate!(@manifest, imp_path, upstream_path)
    end
  end

  test "source, model, and request drift fail closed before a plan exists" do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    path = Path.expand(@manifest)

    assert_raise ArgumentError, ~r/DSPy source commit drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["source_commits", "dspy"], "wrong"),
        path
      )
    end

    assert_raise ArgumentError, ~r/task.temperature drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["execution", "request", "task", "temperature"], 0.1),
        path
      )
    end

    assert_raise ArgumentError, ~r/dataset.contract SHA-256 drift/, fn ->
      Contract.validate!(
        put_in(manifest, ["dataset", "contract_sha256"], String.duplicate("0", 64)),
        path
      )
    end
  end

  test "held-out loading cannot run until every selection has been durably sealed" do
    {:ok, events} = Agent.start_link(fn -> [] end)
    record = fn event -> Agent.update(events, &(&1 ++ [event])) end

    {sealed, held_out} =
      TwoPhase.seal_then_load_held_out!(
        [:baseline, :gepa, :mipro_v2],
        fn arm ->
          record.({:sealed, arm})
          %{arm: arm, artifact_sha256: "sealed-#{arm}"}
        end,
        fn selections ->
          assert Enum.map(selections, & &1.arm) == [:baseline, :gepa, :mipro_v2]
          record.(:selection_receipt_fsynced)
          :ok
        end,
        fn ->
          record.(:held_out_opened)
          [:untouched]
        end
      )

    assert length(sealed) == 3
    assert held_out == [:untouched]

    assert Agent.get(events, & &1) == [
             {:sealed, :baseline},
             {:sealed, :gepa},
             {:sealed, :mipro_v2},
             :selection_receipt_fsynced,
             :held_out_opened
           ]
  end

  test "launch identity records an owned clean Git HEAD and refuses drift" do
    root =
      Path.join(System.tmp_dir!(), "imp-matched-source-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git = fn args ->
      assert {_output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    end

    git.(~w(init))
    git.(["config", "user.email", "imp@example.invalid"])
    git.(["config", "user.name", "Imp Example"])
    File.write!(Path.join(root, "tracked"), "frozen\n")
    git.(~w(add tracked))
    git.(~w(commit -m frozen))

    identity = SourceIdentity.capture_clean!(root, %{"dspy" => "d", "gepa" => "g"})
    assert identity["imp"] =~ ~r/\A[0-9a-f]{40}\z/
    assert Map.take(identity, ~w(dspy gepa)) == %{"dspy" => "d", "gepa" => "g"}

    File.write!(Path.join(root, "drift"), "untracked\n")

    assert_raise RuntimeError, ~r/launch tree is not clean/, fn ->
      SourceIdentity.capture_clean!(root, %{})
    end
  end

  test "response evidence survives a later typed parse failure" do
    envelope = %{
      __imp_lm_output__: "not valid typed output",
      __imp_lm_metadata__: %{
        req_llm: %{
          provider: "ollama",
          model: "llama3.2:3b",
          finish_reason: "stop",
          content: "not valid typed output",
          provider_meta: %{provider: "OpenAI", service_tier: "default"},
          usage: %{input_tokens: 12, output_tokens: 4, cost: 0.1, total_cost: 0.1}
        }
      }
    }

    assert %{
             output: "not valid typed output",
             gateway: "ollama",
             route: "OpenAI",
             service_tier: "default",
             model: "llama3.2:3b",
             finish_reason: "stop",
             content: "not valid typed output",
             input_tokens: 12,
             output_tokens: 4
           } =
             MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!({:ok, envelope})
  end

  test "response evidence normalizes finish enums and preserves zero cost" do
    envelope = %{
      __imp_lm_output__: %{"route" => "K11"},
      __imp_lm_metadata__: %{
        req_llm: %{
          provider: "ollama",
          model: "llama3.2:3b",
          finish_reason: :stop,
          content: "",
          usage: %{input_tokens: 1, output_tokens: 0, cost: 0, total_cost: 0}
        }
      }
    }

    assert %{finish_reason: "stop", provider_cost: 0, computed_cost: 0} =
             MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!({:ok, envelope})
  end

  test "response evidence prefers the gateway scalar over an adapter cost breakdown" do
    envelope = %{
      __imp_lm_output__: %{"route" => "K11"},
      __imp_lm_metadata__: %{
        req_llm: %{
          provider: "openrouter",
          model: "openai/gpt-5.4-mini",
          finish_reason: :stop,
          content: "[[ ## route ## ]]\nK11\n[[ ## completed ## ]]",
          usage: %{
            "cost" => 0.00022125,
            cost: %{total: 0.000222, input_cost: 0.000145, output_cost: 0.000077},
            total_cost: 0.000222
          }
        }
      }
    }

    assert %{
             gateway_reported_cost: 0.00022125,
             provider_cost: 0.00022125,
             computed_cost: 0.000222
           } = MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!({:ok, envelope})
  end

  test "cost reconciliation applies the inclusive decimal microdollar boundary" do
    assert MatchedInstructionOptimizersTREC.ResponseEvidence.costs_reconcile?(
             0.000255,
             0.000254
           )

    refute MatchedInstructionOptimizersTREC.ResponseEvidence.costs_reconcile?(
             0.00025501,
             0.000254
           )
  end

  test "a valid observed response returns the success sentinel required by LM.generate" do
    evidence = %{
      model: "openai/gpt-5.4-mini",
      route: "OpenAI",
      gateway: "openrouter",
      service_tier: "default",
      input_tokens: 202,
      output_tokens: 23,
      finish_reason: "stop",
      content: "[[ ## route ## ]]\nK11\n[[ ## completed ## ]]",
      gateway_reported_cost: 0.000255,
      computed_cost: 0.000254
    }

    expected = %{
      "logical" => "openai/gpt-5.4-mini",
      "imp" => "openai/gpt-5.4-mini",
      "endpoint_provider" => "OpenAI",
      "max_input_tokens" => 4_096,
      "max_output_tokens" => 256
    }

    assert :ok =
             MatchedInstructionOptimizersTREC.ResponseEvidence.validate_contract(
               evidence,
               expected
             )

    assert {:error, {:response_identity_or_usage_drift, _}} =
             MatchedInstructionOptimizersTREC.ResponseEvidence.validate_contract(
               %{evidence | route: "WrongProvider"},
               expected
             )
  end

  test "input ceilings use provider token evidence rather than JSON byte length" do
    evidence = %{
      model: "openai/gpt-5.4-mini",
      route: "OpenAI",
      gateway: "openrouter",
      service_tier: "default",
      input_tokens: 4_096,
      output_tokens: 1,
      finish_reason: "stop",
      content: String.duplicate("x", 4_603),
      gateway_reported_cost: 0.001,
      computed_cost: 0.001
    }

    expected = %{
      "logical" => "openai/gpt-5.4-mini",
      "imp" => "openai/gpt-5.4-mini",
      "endpoint_provider" => "OpenAI",
      "max_input_tokens" => 4_096,
      "max_output_tokens" => 256
    }

    assert :ok =
             MatchedInstructionOptimizersTREC.ResponseEvidence.validate_contract(
               evidence,
               expected
             )

    assert {:error, {:response_identity_or_usage_drift, _}} =
             MatchedInstructionOptimizersTREC.ResponseEvidence.validate_contract(
               %{evidence | input_tokens: 4_097},
               expected
             )

    runner = File.read!("examples/matched_instruction_optimizers_trec/run_imp.exs")
    refute runner =~ "rendered request conservative token bound"
  end

  defp perfect_rows(path) do
    path
    |> File.stream!()
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      expected = if String.starts_with?(row["label"], "DESC:"), do: "K11", else: "K47"

      %{
        "source_id" => row["id"],
        "expected" => expected,
        "parsed_route" => expected,
        "correct" => true,
        "error" => nil
      }
    end)
  end

  defp assert_file_receipt!(path, receipt) do
    bytes = File.read!(path)
    assert byte_size(bytes) == receipt["bytes"]

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == receipt["sha256"]
  end
end
