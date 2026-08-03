defmodule Imp.BenchmarkTruth.GepaStudyPlan do
  @moduledoc false

  alias Imp.BenchmarkTruth.GepaSuite
  alias Imp.Optimizer.GEPA

  @dataset_summary_batch_size 10
  @dataset_summary_batch_limit 10
  @mipro_heavy_instruction_candidates 9
  @mipro_program_aware_calls_per_candidate 3
  @fresh_examples_per_selected_arm 4
  @selected_arms 2
  @chat_json_fallback_transport_factor 2

  @family_shape %{
    "AIMEBench" => %{predictors: 1, task_stages: 1, judge_stages: 0},
    "HotpotQABench" => %{predictors: 4, task_stages: 4, judge_stages: 0},
    "hoverBench" => %{predictors: 4, task_stages: 4, judge_stages: 0},
    "IFBench" => %{predictors: 2, task_stages: 2, judge_stages: 0},
    "LiveBenchMathBench" => %{predictors: 1, task_stages: 1, judge_stages: 0},
    "Papillon" => %{predictors: 2, task_stages: 3, judge_stages: 3}
  }

  @doc "Derives the complete provider-opportunity bound for the matched six-task study."
  def plan!(dataset_root, opts \\ []) when is_binary(dataset_root) and is_list(opts) do
    seeds = Keyword.get(opts, :seeds, 3)
    runtimes = Keyword.get(opts, :runtimes, 2)

    unless is_integer(seeds) and seeds > 0,
      do: raise(ArgumentError, "study seed count must be a positive integer")

    unless is_integer(runtimes) and runtimes > 0,
      do: raise(ArgumentError, "study runtime count must be a positive integer")

    families = Enum.map(GepaSuite.families(), &family_plan!(dataset_root, &1))
    lanes = seeds * runtimes
    per_lane = sum_families(families)
    per_lane_by_arm = sum_arms(families)

    %{
      kind: :matched_current_model_gepa_suite,
      protocol_classification: :adapted_current_model_reference_differential,
      paper_replication_claimed: false,
      arms: [:baseline, :mipro_v2_heavy, :gepa_v0_1_4_no_merge],
      execution_sequence: [
        {:vertical, "AIMEBench", [:baseline, :gepa_v0_1_4_no_merge, :mipro_v2_heavy]},
        {:vertical, "IFBench", [:baseline, :gepa_v0_1_4_no_merge, :mipro_v2_heavy]},
        {:scale_remaining_after_review,
         ["HotpotQABench", "hoverBench", "LiveBenchMathBench", "Papillon"]}
      ],
      seeds: seeds,
      runtimes: runtimes,
      lanes: lanes,
      families: families,
      per_runtime_seed: per_lane,
      per_runtime_seed_by_arm: per_lane_by_arm,
      full_study: multiply(per_lane, lanes),
      full_study_by_arm:
        Map.new(per_lane_by_arm, fn {arm, totals} -> {arm, multiply(totals, lanes)} end),
      boundaries: %{
        preserves_full_six_family_endpoint: true,
        vertical_sequence_is_not_a_success_gate: true,
        current_gepa_profile: :gepa_v0_1_4_no_merge,
        exact_paper_replication_requires_separate_protocol: true,
        heldout_loaded_after_optimizer: true,
        official_mipro_reference_opportunity: true,
        gepa_boundary_checked_legal_completion: true,
        mipro_proposer_calls_are_legal_maximum: true,
        fresh_examples_per_selected_arm: @fresh_examples_per_selected_arm,
        selected_arms: @selected_arms,
        task_transport_bound: :initial_chat_call_plus_at_most_one_ordinary_json_adapter_fallback,
        provider_calls_authorized: false
      }
    }
  end

  defp family_plan!(dataset_root, family) do
    %{spec: spec} = GepaSuite.load!(dataset_root, family)
    shape = Map.fetch!(@family_shape, family)
    train = get_in(spec, ["split_counts", "train"])
    dev = get_in(spec, ["split_counts", "dev"])
    test = get_in(spec, ["split_counts", "test"])
    mipro_metric_calls = Map.fetch!(spec, "metric_calls")
    gepa = GEPA.v014_budget_envelope(dev, 3, mipro_metric_calls)

    program_evaluations =
      test + mipro_metric_calls + test + gepa.max_metric_calls + test

    task_transports = legal_task_transports(program_evaluations, shape.task_stages)
    judge_transports = program_evaluations * shape.judge_stages

    fresh_program_evaluations = @fresh_examples_per_selected_arm * @selected_arms

    fresh_task_transports =
      legal_task_transports(fresh_program_evaluations, shape.task_stages)

    summary_batches = div(train + @dataset_summary_batch_size - 1, @dataset_summary_batch_size)
    summary_calls = min(summary_batches, @dataset_summary_batch_limit) + 1

    mipro_proposer_transports =
      summary_calls +
        shape.predictors * @mipro_heavy_instruction_candidates *
          @mipro_program_aware_calls_per_candidate

    arms = %{
      baseline:
        arm_totals(
          test,
          legal_task_transports(test, shape.task_stages),
          test * shape.judge_stages,
          0,
          0
        ),
      mipro_v2_heavy:
        arm_totals(
          mipro_metric_calls + test,
          legal_task_transports(
            mipro_metric_calls + test + @fresh_examples_per_selected_arm,
            shape.task_stages
          ),
          (mipro_metric_calls + test) * shape.judge_stages,
          mipro_proposer_transports,
          0
        ),
      gepa_v0_1_4_no_merge:
        arm_totals(
          gepa.max_metric_calls + test,
          legal_task_transports(
            gepa.max_metric_calls + test + @fresh_examples_per_selected_arm,
            shape.task_stages
          ),
          (gepa.max_metric_calls + test) * shape.judge_stages,
          0,
          gepa.max_reflection_calls
        )
    }

    %{
      family: family,
      program: spec["program"],
      train: train,
      dev: dev,
      test: test,
      predictors: shape.predictors,
      task_stages: shape.task_stages,
      task_transport_factor: @chat_json_fallback_transport_factor,
      judge_stages: shape.judge_stages,
      program_evaluations: %{
        baseline_test: test,
        mipro_optimizer: mipro_metric_calls,
        mipro_test: test,
        gepa_optimizer_legal: gepa.max_metric_calls,
        gepa_test: test,
        total: program_evaluations
      },
      transports: %{
        task: task_transports + fresh_task_transports,
        judge: judge_transports,
        mipro_proposer: mipro_proposer_transports,
        gepa_reflection: gepa.max_reflection_calls,
        total:
          task_transports + fresh_task_transports + judge_transports +
            mipro_proposer_transports + gepa.max_reflection_calls
      },
      fresh: %{
        program_evaluations: fresh_program_evaluations,
        task_transports: fresh_task_transports
      },
      gepa: %{
        semantic_metric_calls: mipro_metric_calls,
        legal_metric_calls: gepa.max_metric_calls,
        logical_iterations: gepa.max_iterations,
        legal_reflection_transports: gepa.max_reflection_calls
      },
      mipro: %{
        auto: :heavy,
        instruction_candidates: @mipro_heavy_instruction_candidates,
        dataset_summary_calls: summary_calls,
        legal_proposer_transports: mipro_proposer_transports
      },
      arms: arms
    }
  end

  defp legal_task_transports(program_evaluations, task_stages) do
    program_evaluations * task_stages * @chat_json_fallback_transport_factor
  end

  defp arm_totals(program_evaluations, task, judge, mipro_proposer, gepa_reflection) do
    %{
      program_evaluations: program_evaluations,
      task_transports: task,
      judge_transports: judge,
      mipro_proposer_transports: mipro_proposer,
      gepa_reflection_transports: gepa_reflection,
      total_transports: task + judge + mipro_proposer + gepa_reflection
    }
  end

  defp sum_arms(families) do
    Enum.reduce(families, %{}, fn family, arms ->
      Map.merge(arms, family.arms, fn _arm, left, right -> add_totals(left, right) end)
    end)
  end

  defp sum_families(families) do
    Enum.reduce(families, zero_totals(), fn family, totals ->
      %{
        program_evaluations: totals.program_evaluations + family.program_evaluations.total,
        task_transports: totals.task_transports + family.transports.task,
        judge_transports: totals.judge_transports + family.transports.judge,
        mipro_proposer_transports:
          totals.mipro_proposer_transports + family.transports.mipro_proposer,
        gepa_reflection_transports:
          totals.gepa_reflection_transports + family.transports.gepa_reflection,
        total_transports: totals.total_transports + family.transports.total
      }
    end)
  end

  defp zero_totals do
    %{
      program_evaluations: 0,
      task_transports: 0,
      judge_transports: 0,
      mipro_proposer_transports: 0,
      gepa_reflection_transports: 0,
      total_transports: 0
    }
  end

  defp add_totals(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.fetch!(right, key)} end)
  end

  defp multiply(totals, lanes) do
    Map.new(totals, fn {key, value} -> {key, value * lanes} end)
  end
end
