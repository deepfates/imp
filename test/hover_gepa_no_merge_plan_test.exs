defmodule Imp.BenchmarkTruth.HoverGepaNoMergePlanTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.HoverGepaNoMergePlan

  @tag :evidence_infrastructure
  test "authenticates the no-merge authorities and derives nominal and legal opportunity" do
    assert :ok = HoverGepaNoMergePlan.verify_authorities!()
    plan = HoverGepaNoMergePlan.design()

    assert plan.status == :readiness_only
    assert plan.data_readiness.data_ready == false
    assert plan.data_readiness.reason =~ "build-receipt"
    assert plan.retrieval.authority_scope == :condition_build_instance_receipt
    assert plan.retrieval.planned_runtime_entries == [:imp, :dspy]

    assert plan.retrieval.index_build_instance_tree_sha256 ==
             "d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548"

    assert plan.retrieval.frozen_claim_retrieval_fingerprint_sha256 ==
             "2662ef6b6a4f8f80b9d348992f14ca04d3007c84b13252825dc38a55ace22099"

    assert plan.rows == %{train: 150, selection: 300, test: 300}
    assert plan.split_policy.output_blind

    assert plan.split_policy.kind ==
             :released_split_with_content_identity_overlap_removed

    assert plan.optimizer.execution_profile == :gepa_v0_1_4
    refute plan.optimizer.use_merge
    assert plan.optimizer.semantic_max_metric_calls == 4_500
    assert plan.optimizer.operational_metric_calls == 4_803
    assert plan.optimizer.generations == 1_400
    assert plan.optimizer.logical_reflections == 1_400
    assert plan.optimizer.legal_reflection_transports == 2_800
    assert plan.transports.nominal_task_per_runtime_seed == 32_400
    assert plan.transports.legal_task_per_runtime_seed == 33_612
    assert plan.transports.nominal_total == 194_448
    assert plan.transports.legal_total == 201_720
    assert plan.transports.logical_reflections_all_runtimes_seeds == 8_400
    assert plan.transports.legal_reflection_transports_all_runtimes_seeds == 16_800
    assert plan.historical_artifact.task_model == "openai:gpt-4.1-mini-2025-04-14"
    assert plan.historical_artifact.treatment_status == :provenance_only

    assert plan.current_treatment.status == :provider_free_candidate
    assert plan.current_treatment.applies_to == [:imp, :dspy]
    assert plan.current_treatment.task_model == "deepseek/deepseek-v4-flash-0731"
    assert plan.current_treatment.reflection_model == "anthropic/claude-sonnet-5"
    refute plan.current_treatment.same_route_for_task_and_reflection
    assert plan.current_treatment.task_route.endpoint_tag == "siliconflow/fp8"
    assert plan.current_treatment.reflection_route.endpoint_tag == "google-vertex/global"

    assert plan.current_treatment.concurrency == %{
             status: :pending_matched_policy,
             imp_optimizer: 1,
             upstream_threads: :pending,
             candidate_task_and_outer: 16,
             reflection: 1,
             result_order: :source_row_order,
             blocker:
               "pinned Imp GEPA v0.1.4 requires serial optimizer evaluation; a matched operational policy is not yet proven"
           }

    assert plan.current_treatment.matched_contract == %{
             rows: :exact,
             information: :same,
             optimizer_opportunity: :same,
             generation_policies: :target_pending_both_serializers,
             renderer: :runtime_native,
             result_order: :source_row_order
           }

    assert plan.current_treatment.readiness == %{
             imp_provider_disabled_lifecycle: :exercised,
             dspy_provider_disabled_lifecycle: :pending_repository_only_entry,
             imp_live_request_serialization: :pending,
             dspy_live_request_serialization: :pending,
             exact_route_cost_calibration: :pending,
             provider_authority: false
           }

    assert plan.current_treatment.policies.task == %{
             temperature: 1.0,
             top_p: 1.0,
             reasoning: :disabled,
             max_output_tokens: 2_048,
             max_output_bytes: 32_768,
             request_seed: nil
           }

    assert plan.current_treatment.policies.reflection == %{
             temperature: :omitted,
             verbosity: :omitted,
             reasoning_effort: :high,
             max_output_tokens: 8_192,
             max_output_bytes: 65_536,
             request_seed: nil
           }

    assert plan.current_treatment.guards.task.max_input_bytes == 131_072
    assert plan.current_treatment.guards.reflection.max_input_bytes == 655_360
    assert plan.reservation.prospective_spend_cap == :pending_train_only_calibration
    assert_in_delta plan.reservation.nominal_usd, 15_377.81661696, 1.0e-9
    assert_in_delta plan.reservation.legal_usd, 27_213.60445440, 1.0e-9
  end

  test "candidate task and reflection routes are exact, ZDR-listed, and fail closed" do
    task = task_endpoint()
    reflection = reflection_endpoint()

    assert %{task: %{"tag" => "siliconflow/fp8"}, reflection: %{"tag" => "google-vertex/global"}} =
             HoverGepaNoMergePlan.validate_candidate_catalog!(
               %{
                 "data" => %{"id" => "deepseek/deepseek-v4-flash-0731", "endpoints" => [task]}
               },
               %{"data" => [task]},
               %{"data" => %{"id" => "anthropic/claude-sonnet-5", "endpoints" => [reflection]}},
               %{"data" => [reflection]}
             )

    assert HoverGepaNoMergePlan.candidate_provider_preferences(:task) == %{
             only: ["siliconflow/fp8"],
             order: ["siliconflow/fp8"],
             allow_fallbacks: false,
             require_parameters: true,
             data_collection: "deny",
             zdr: true,
             max_price: %{prompt: 0.14, completion: 0.28}
           }

    assert HoverGepaNoMergePlan.candidate_provider_preferences(:reflection).max_price == %{
             prompt: 2.0,
             completion: 10.0
           }

    assert_raise ArgumentError, ~r/endpoint drift/, fn ->
      HoverGepaNoMergePlan.validate_candidate_catalog!(
        %{
          "data" => %{
            "id" => "deepseek/deepseek-v4-flash-0731",
            "endpoints" => [put_in(task, ["pricing", "completion"], "0.00000029")]
          }
        },
        %{"data" => [task]},
        %{"data" => %{"id" => "anthropic/claude-sonnet-5", "endpoints" => [reflection]}},
        %{"data" => [reflection]}
      )
    end

    assert_raise ArgumentError, ~r/one exact endpoint/, fn ->
      HoverGepaNoMergePlan.validate_candidate_catalog!(
        %{"data" => %{"id" => "deepseek/deepseek-v4-flash-0731", "endpoints" => [task]}},
        %{"data" => []},
        %{"data" => %{"id" => "anthropic/claude-sonnet-5", "endpoints" => [reflection]}},
        %{"data" => [reflection]}
      )
    end
  end

  @tag :evidence_infrastructure
  test "condition receipt requires both runtimes, exact receipt, and exact fingerprint" do
    root = Path.expand("tmp/hover-materialization-v1")
    data_root = Path.join(root, "export-disjoint-v1/hoverBench")
    receipt_path = Path.join(root, "materialization.json")
    split_receipt_path = Path.join(root, "export-disjoint-v1/families.json")
    lock_path = Path.join(root, "dependency-lock.txt")

    fingerprint_path =
      Path.join(root, "retrieval/frozen-disjoint-claim-retrieval-fingerprint.jsonl")

    corpus_path = Path.join(root, "retrieval/extracted/wiki.abstracts.2017.jsonl")
    index_path = Path.join(root, "retrieval/index/bm25s_retriever")

    retrieval = %{
      "kind" => "bm25s_wiki_abstracts_2017",
      "corpus_path" => corpus_path,
      "index_path" => index_path,
      "corpus_checksum" =>
        "sha256:c006527c7c600f85ed594afa36d2a34d0598996405f560474227738342463724",
      "index_checksum" =>
        "sha256:d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548"
    }

    common = [
      data_root: data_root,
      receipt_path: receipt_path,
      split_receipt_path: split_receipt_path,
      dependency_lock_path: lock_path,
      fingerprint_path: fingerprint_path
    ]

    assert_raise ArgumentError, ~r/Imp and DSPy/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        Keyword.put(common, :runtime_retrievals, %{imp: retrieval})
      )
    end

    altered_receipt = temporary_path("altered-receipt")

    File.write!(
      altered_receipt,
      File.read!(receipt_path)
      |> String.replace(
        "d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548",
        String.duplicate("0", 64),
        global: false
      )
    )

    on_exit(fn -> File.rm_rf!(altered_receipt) end)

    assert_raise ArgumentError, ~r/build receipt/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        common
        |> Keyword.put(:receipt_path, altered_receipt)
        |> Keyword.put(:runtime_retrievals, %{imp: retrieval, dspy: retrieval})
      )
    end

    altered_fingerprint = temporary_path("altered-fingerprint")
    File.write!(altered_fingerprint, File.read!(fingerprint_path) <> "{}\n")
    on_exit(fn -> File.rm_rf!(altered_fingerprint) end)

    assert_raise ArgumentError, ~r/fingerprint/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        common
        |> Keyword.put(:fingerprint_path, altered_fingerprint)
        |> Keyword.put(:runtime_retrievals, %{imp: retrieval, dspy: retrieval})
      )
    end

    assert %{data_ready: true, runtime_entries: [:imp, :dspy]} =
             HoverGepaNoMergePlan.data_readiness(
               Keyword.put(common, :runtime_retrievals, %{imp: retrieval, dspy: retrieval})
             )
  end

  test "constructs only the frozen public pinned profile" do
    metric = fn _example, _prediction -> 1.0 end
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "unused" end)

    optimizer = HoverGepaNoMergePlan.optimizer(metric, lm, 2_026_080_201)

    assert optimizer.execution_profile == :gepa_v0_1_4
    assert optimizer.reflection_record_mode == :gepa_v0_1_4
    assert optimizer.module_selector == :round_robin
    refute optimizer.use_merge
    assert optimizer.minibatch_size == 3
    assert optimizer.generations == 1_400
    assert optimizer.max_metric_calls == 4_500
    assert optimizer.max_reflection_calls == 2_800

    assert Enum.sort(Map.keys(optimizer.component_feedback)) ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]

    assert_raise ArgumentError, ~r/unfrozen HoVer seed/, fn ->
      HoverGepaNoMergePlan.optimizer(metric, lm, 17)
    end
  end

  @tag :evidence_infrastructure
  test "loads the exact source splits and keeps one resident source-exact retriever" do
    root = Path.expand("tmp/hover-materialization-v1")
    data = HoverGepaNoMergePlan.data!(root)

    assert length(data.train) == 150
    assert length(data.selection) == 300
    assert length(data.test) == 300

    retrieval = HoverGepaNoMergePlan.source_exact_retrieval_probe!(root)
    assert retrieval.queries == 16
    assert retrieval.top_k == 24
    assert retrieval.repeat_exact
    assert retrieval.fingerprint_exact
    assert retrieval.implementation == "resident_upstream_python_bm25s"

    census = HoverGepaNoMergePlan.train_only_reflection_census!(root)
    assert census.scope == :authenticated_train_three_row_four_stage_traces
    assert census.train_rows_available == 150
    refute census.selection_or_test_loaded

    assert census.observed_provider_free == %{
             p50_bytes: 3_050,
             p95_bytes: 12_972,
             max_bytes: 12_972,
             live_distribution_claim: false
           }

    assert census.synthetic_planning_case.rendered_bytes == 607_541
    assert census.guard_bytes == 655_360
    assert census.guard_status == :candidate_pending_real_request_builders
    refute census.context_safety_proven
  end

  @tag :evidence_infrastructure
  test "compact provider-disabled lifecycle exercises four mutations, rejection, selection, and fresh service" do
    root = temporary_path("lifecycle")
    on_exit(fn -> File.rm_rf!(root) end)

    result = HoverGepaNoMergePlan.provider_disabled_lifecycle!(root, 2_026_080_201)

    assert result.proposal_components == [
             "summarize1",
             "create_query_hop2",
             "summarize2",
             "create_query_hop3",
             "summarize1"
           ]

    assert result.changed_predictors ==
             ~w(create_query_hop2 create_query_hop3 summarize1 summarize2)

    assert result.rejected_candidates == 1
    assert result.optimizer_metric_calls == 50
    assert result.optimizer_reflection_calls == 5
    assert result.reflection_prompt_census.count == 5
    assert result.reflection_prompt_census.synthetic_planning_case.rendered_bytes == 607_541
    assert result.baseline_selection == 0.0
    assert_in_delta result.optimized_selection, 0.8, 1.0e-12
    assert result.selected == :optimized
    assert result.baseline_test == 0.0
    assert_in_delta result.selected_test, 0.8, 1.0e-12
    assert result.fresh_service == %{"all_ok" => true, "calls" => 4}
    assert File.exists?(Path.join(root, "artifact-2026080201.json"))
    assert File.exists?(Path.join(root, "result-2026080201.json"))
  end

  @tag :evidence_infrastructure
  test "provider-disabled invocation authenticates the plan and runs all three compact seeds" do
    root = temporary_path("entry")
    on_exit(fn -> File.rm_rf!(root) end)

    {output, 0} =
      System.cmd(
        "mix",
        [
          "run",
          "scripts/hover_gepa_no_merge_current.exs",
          "--output-root",
          root,
          "--material-root",
          Path.expand("tmp/hover-materialization-v1")
        ],
        env: [{"OPENAI_API_KEY", ""}, {"ANTHROPIC_API_KEY", ""}],
        stderr_to_stdout: true
      )

    payload = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert get_in(payload, ["plan", "condition"]) ==
             "imp-88sn-hover-gepa-no-merge-current-model-v2"

    assert get_in(payload, ["plan", "data_readiness", "data_ready"]) == true

    assert get_in(payload, ["source_exact_retrieval_probe", "queries"]) == 16
    assert get_in(payload, ["source_exact_retrieval_probe", "repeat_exact"])

    assert get_in(payload, ["train_only_reflection_census", "scope"]) ==
             "authenticated_train_three_row_four_stage_traces"

    assert get_in(payload, ["train_only_reflection_census", "selection_or_test_loaded"]) == false

    assert payload["reflection_census_scope"] == %{
             "census_data_access" => "train_only",
             "invocation_preflight" => "all_split_identity_authentication"
           }

    assert Enum.map(payload["provider_disabled_results"], & &1["seed"]) ==
             [2_026_080_201, 2_026_080_202, 2_026_080_203]

    assert Enum.all?(payload["provider_disabled_results"], fn result ->
             result["fresh_service"] == %{"all_ok" => true, "calls" => 4} and
               result["proposal_components"] ==
                 ~w(summarize1 create_query_hop2 summarize2 create_query_hop3 summarize1)
           end)
  end

  defp temporary_path(name) do
    Path.join(System.tmp_dir!(), "imp-hover-plan-#{System.unique_integer([:positive])}-#{name}")
  end

  defp task_endpoint do
    %{
      "tag" => "siliconflow/fp8",
      "name" => "SiliconFlow | deepseek/deepseek-v4-flash-20260731",
      "model_id" => "deepseek/deepseek-v4-flash-0731",
      "provider_name" => "SiliconFlow",
      "quantization" => "fp8",
      "status" => 0,
      "supports_implicit_caching" => false,
      "pricing" => %{"prompt" => "0.00000014", "completion" => "0.00000028"},
      "supported_parameters" => ~w(reasoning temperature top_p max_tokens)
    }
  end

  defp reflection_endpoint do
    %{
      "tag" => "google-vertex/global",
      "name" => "Google | anthropic/claude-sonnet-5-20260630",
      "model_id" => "anthropic/claude-sonnet-5",
      "provider_name" => "Google",
      "quantization" => "unknown",
      "context_length" => 1_000_000,
      "status" => 0,
      "supports_implicit_caching" => false,
      "pricing" => %{"prompt" => "0.000002", "completion" => "0.00001"},
      "supported_parameters" => ~w(reasoning reasoning_effort max_tokens stop tools verbosity)
    }
  end
end
