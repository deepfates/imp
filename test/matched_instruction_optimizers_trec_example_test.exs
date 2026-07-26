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
             "gepa" => %{"task_calls" => 400, "optimizer_calls" => 8, "total_calls" => 408},
             "mipro_v2" => %{"task_calls" => 620, "optimizer_calls" => 9, "total_calls" => 629}
           }

    assert plan["worst_case"] == %{
             "task_calls" => 6_840,
             "optimizer_calls" => 102,
             "total_calls" => 6_942,
             "input_tokens" => 29_687_808,
             "output_tokens" => 1_855_488,
             "usd" => 38.43072
           }

    assert get_in(plan, ["runtime_configs", "imp", "adapter_rendering"]) ==
             "byte_identical_baseline_and_frozen_injected_instruction_probe; live candidate instructions must be rendered; optimizer trajectories may diverge"

    assert get_in(plan, ["runtime_configs", "upstream", "capture", "rendered_messages"])

    assert get_in(plan, ["runtime_configs", "imp", "arm_call_ceilings"]) ==
             get_in(plan, ["runtime_configs", "upstream", "arm_call_ceilings"])
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
    assert output =~ "Ran 10 tests"
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
end
