defmodule Imp.BenchmarkTruth.GepaStudyPlanTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.GepaStudyPlan

  @root "tmp/gepa-six-task-current-root"

  @tag :evidence_infrastructure
  test "derives the complete three-seed two-runtime opportunity from official receipts" do
    plan = GepaStudyPlan.plan!(@root, seeds: 3, runtimes: 2)

    assert plan.arms == [:baseline, :mipro_v2_heavy, :gepa_v0_1_4_merge]
    assert plan.protocol_classification == :adapted_current_model_reference_differential
    refute plan.paper_replication_claimed
    assert plan.baseline_protocol_status == :executable
    assert plan.optimizer_protocol_status == :requires_budget_ratification

    assert plan.execution_sequence == [
             {:complete_full_baseline_sweep,
              ~w(AIMEBench HotpotQABench hoverBench IFBench LiveBenchMathBench Papillon)},
             {:repair_or_ratify_merge_enabled_gepa,
              ~w(AIMEBench HotpotQABench hoverBench IFBench LiveBenchMathBench Papillon)},
             {:run_full_optimizer_sweep,
              ~w(AIMEBench HotpotQABench hoverBench IFBench LiveBenchMathBench Papillon)}
           ]

    assert plan.reference_artifact == %{
             source_commit: "cbefbc1aa0f43dd39874ec4bf42211365dbda42e",
             generated_seed_count: 1,
             generated_seed: 0,
             heldout_evaluations_per_arm: 1,
             optimizer_arms: [:mipro_v2_heavy, :gepa_merge, :gepa_no_merge],
             gepa_budget_source: :observed_mipro_v2_heavy_metric_calls
           }

    assert plan.lanes == 6
    assert plan.seed_values == [2_026_080_101, 2_026_080_102, 2_026_080_103]
    assert plan.current_protocol_additions.fixed_seeds == plan.seed_values

    assert plan.per_runtime_seed == %{
             program_evaluations: 52_614,
             task_transports: 326_256,
             judge_transports: 16_890,
             mipro_proposer_transports: 439,
             gepa_reflection_transports: 14_966,
             total_transports: 358_551
           }

    assert plan.full_study == %{
             program_evaluations: 315_684,
             task_transports: 1_957_536,
             judge_transports: 101_340,
             mipro_proposer_transports: 2_634,
             gepa_reflection_transports: 89_796,
             total_transports: 2_151_306
           }

    assert plan.nominal_per_runtime_seed == %{
             program_evaluations: 51_411,
             task_transports: 159_561,
             judge_transports: 16_545,
             mipro_proposer_transports: 439,
             gepa_reflection_transports: 7_483,
             total_transports: 184_028
           }

    assert plan.nominal_study == %{
             program_evaluations: 308_466,
             task_transports: 957_366,
             judge_transports: 99_270,
             mipro_proposer_transports: 2_634,
             gepa_reflection_transports: 44_898,
             total_transports: 1_104_168
           }

    assert plan.per_runtime_seed_by_arm.baseline == %{
             program_evaluations: 1_391,
             task_transports: 7_854,
             judge_transports: 663,
             mipro_proposer_transports: 0,
             gepa_reflection_transports: 0,
             total_transports: 8_517
           }

    first_baseline = GepaStudyPlan.plan!(@root, seeds: 1, runtimes: 2)
    assert first_baseline.seed_values == [2_026_080_101]

    assert first_baseline.full_study_by_arm.baseline == %{
             program_evaluations: 2_782,
             task_transports: 15_708,
             judge_transports: 1_326,
             mipro_proposer_transports: 0,
             gepa_reflection_transports: 0,
             total_transports: 17_034
           }

    summed_arms =
      plan.per_runtime_seed_by_arm
      |> Map.values()
      |> Enum.reduce(%{}, fn totals, acc ->
        Map.merge(acc, totals, fn _key, left, right -> left + right end)
      end)

    assert summed_arms == plan.per_runtime_seed

    assert Enum.map(plan.families, & &1.family) ==
             ~w(AIMEBench HotpotQABench hoverBench IFBench LiveBenchMathBench Papillon)

    assert Enum.find(plan.families, &(&1.family == "Papillon")).transports.judge == 16_890
    assert plan.boundaries.provider_calls_authorized == false
    assert plan.boundaries.preserves_full_six_family_endpoint
    assert plan.boundaries.baseline_sweep_is_not_a_success_gate
    assert plan.boundaries.current_gepa_profile == :gepa_v0_1_4_merge
    assert plan.boundaries.pinned_dspy_gepa_default_uses_merge
    assert plan.boundaries.no_merge_retained_as_ablation_only
    assert plan.boundaries.exact_paper_replication_requires_separate_protocol

    assert plan.boundaries.task_transport_bound ==
             :initial_chat_call_plus_at_most_one_ordinary_json_adapter_fallback

    assert plan.analysis_contract.primary_table ==
             :per_task_runtime_optimizer_seed_heldout_score

    assert plan.analysis_contract.within_runtime_effect == :optimizer_minus_matched_baseline
    assert plan.analysis_contract.cross_runtime_effect == :imp_lift_minus_dspy_lift
    refute plan.analysis_contract.private_universal_victory_threshold
    refute plan.analysis_contract.task_removal_after_outcomes
    refute plan.analysis_contract.continuation_based_on_interim_scores
  end

  @tag :evidence_infrastructure
  test "requires explicit seed identities to be unique and count-matched" do
    assert_raise ArgumentError, ~r/unique integers/, fn ->
      GepaStudyPlan.plan!(@root, seed_values: [7, 7])
    end

    assert_raise ArgumentError, ~r/must equal/, fn ->
      GepaStudyPlan.plan!(@root, seeds: 3, seed_values: [7, 8])
    end
  end
end
