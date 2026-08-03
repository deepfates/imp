defmodule Imp.BenchmarkTruth.GepaStudyPlanTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.GepaStudyPlan

  @root "tmp/gepa-six-task-current-root"

  @tag :evidence_infrastructure
  test "derives the complete three-seed two-runtime opportunity from official receipts" do
    plan = GepaStudyPlan.plan!(@root, seeds: 3, runtimes: 2)

    assert plan.arms == [:baseline, :mipro_v2_heavy, :gepa_v0_1_4_no_merge]
    assert plan.protocol_classification == :adapted_current_model_reference_differential
    refute plan.paper_replication_claimed

    assert plan.execution_sequence == [
             {:vertical, "AIMEBench", [:baseline, :gepa_v0_1_4_no_merge, :mipro_v2_heavy]},
             {:vertical, "IFBench", [:baseline, :gepa_v0_1_4_no_merge, :mipro_v2_heavy]},
             {:scale_remaining_after_review,
              ["HotpotQABench", "hoverBench", "LiveBenchMathBench", "Papillon"]}
           ]

    assert plan.lanes == 6

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

    assert plan.per_runtime_seed_by_arm.baseline == %{
             program_evaluations: 1_391,
             task_transports: 7_854,
             judge_transports: 663,
             mipro_proposer_transports: 0,
             gepa_reflection_transports: 0,
             total_transports: 8_517
           }

    first_baseline = GepaStudyPlan.plan!(@root, seeds: 1, runtimes: 2)

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
    assert plan.boundaries.vertical_sequence_is_not_a_success_gate
    assert plan.boundaries.current_gepa_profile == :gepa_v0_1_4_no_merge
    assert plan.boundaries.exact_paper_replication_requires_separate_protocol

    assert plan.boundaries.task_transport_bound ==
             :initial_chat_call_plus_at_most_one_ordinary_json_adapter_fallback
  end
end
