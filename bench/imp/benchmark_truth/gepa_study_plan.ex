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
  @fixed_seed_values [2_026_080_101, 2_026_080_102, 2_026_080_103]

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
    seed_values = fixed_seed_values!(opts)
    seeds = length(seed_values)
    runtimes = Keyword.get(opts, :runtimes, 2)

    unless is_integer(seeds) and seeds > 0,
      do: raise(ArgumentError, "study seed count must be a positive integer")

    unless is_integer(runtimes) and runtimes > 0,
      do: raise(ArgumentError, "study runtime count must be a positive integer")

    families = Enum.map(GepaSuite.families(), &family_plan!(dataset_root, &1))
    lanes = seeds * runtimes
    per_lane = sum_families(families)
    per_lane_by_arm = sum_arms(families)
    nominal_per_lane = sum_family_totals(families, :nominal_transports)
    nominal_per_lane_by_arm = sum_family_arms(families, :nominal_arms)

    %{
      kind: :matched_current_model_gepa_suite,
      protocol_classification: :adapted_current_model_reference_differential,
      paper_replication_claimed: false,
      baseline_protocol_status: :executable,
      optimizer_protocol_status: :requires_budget_ratification,
      arms: [:baseline, :mipro_v2_heavy, :gepa_v0_1_4_merge],
      execution_sequence: [
        {:complete_full_baseline_sweep, GepaSuite.families()},
        {:repair_or_ratify_merge_enabled_gepa, GepaSuite.families()},
        {:run_full_optimizer_sweep, GepaSuite.families()}
      ],
      reference_artifact: %{
        source_commit: "cbefbc1aa0f43dd39874ec4bf42211365dbda42e",
        generated_seed_count: 1,
        generated_seed: 0,
        heldout_evaluations_per_arm: 1,
        optimizer_arms: [:mipro_v2_heavy, :gepa_merge, :gepa_no_merge],
        gepa_budget_source: :observed_mipro_v2_heavy_metric_calls
      },
      current_protocol_additions: %{
        fixed_seeds: seed_values,
        selected_artifact_fresh_service_examples: @fresh_examples_per_selected_arm,
        selected_arms_with_fresh_service: @selected_arms,
        strict_no_cache_no_retry_route_evidence: true,
        task_json_fallback_is_a_legal_failure_envelope_not_scheduled_work: true
      },
      seeds: seeds,
      seed_values: seed_values,
      runtimes: runtimes,
      lanes: lanes,
      families: families,
      nominal_per_runtime_seed: nominal_per_lane,
      nominal_per_runtime_seed_by_arm: nominal_per_lane_by_arm,
      nominal_study: multiply(nominal_per_lane, lanes),
      nominal_study_by_arm:
        Map.new(nominal_per_lane_by_arm, fn {arm, totals} ->
          {arm, multiply(totals, lanes)}
        end),
      per_runtime_seed: per_lane,
      per_runtime_seed_by_arm: per_lane_by_arm,
      full_study: multiply(per_lane, lanes),
      full_study_by_arm:
        Map.new(per_lane_by_arm, fn {arm, totals} -> {arm, multiply(totals, lanes)} end),
      boundaries: %{
        preserves_full_six_family_endpoint: true,
        baseline_sweep_is_not_a_success_gate: true,
        current_gepa_profile: :gepa_v0_1_4_merge,
        pinned_dspy_gepa_default_uses_merge: true,
        no_merge_retained_as_ablation_only: true,
        exact_paper_replication_requires_separate_protocol: true,
        heldout_loaded_after_optimizer: true,
        official_mipro_reference_opportunity: true,
        gepa_boundary_checked_legal_completion: true,
        mipro_proposer_calls_are_legal_maximum: true,
        fresh_examples_per_selected_arm: @fresh_examples_per_selected_arm,
        selected_arms: @selected_arms,
        task_transport_bound: :initial_chat_call_plus_at_most_one_ordinary_json_adapter_fallback,
        provider_calls_authorized: false
      },
      analysis_contract: %{
        primary_table: :per_task_runtime_optimizer_seed_heldout_score,
        within_runtime_effect: :optimizer_minus_matched_baseline,
        cross_runtime_effect: :imp_lift_minus_dspy_lift,
        paired_row_bootstrap: %{
          eligible_metrics: :all_six_frozen_row_metrics,
          confidence_level: 0.95,
          resamples: 10_000,
          rng: :exsss,
          seed_derivation: %{
            identity: :canonical_json_list_of_task_runtime_optimizer_seed_metric_and_comparison,
            rng_seed:
              :first_twelve_sha256_bytes_as_three_consecutive_unsigned_big_endian_32_bit_words
          },
          unit: :heldout_row_index_paired_across_every_arm_in_the_estimand,
          sampling: :sample_n_row_indexes_with_replacement_from_the_frozen_n_rows_per_resample,
          estimator: :arithmetic_mean_of_paired_row_score_differences,
          interval: %{
            method: :percentile_nearest_rank,
            sorted_zero_based_indexes: %{lower: 249, upper: 9_749}
          }
        },
        seed_uncertainty: %{
          inferential_interval: false,
          report: [:all_three_values, :arithmetic_mean, :median, :minimum, :maximum]
        },
        secondary_macro: %{
          task_weighting: :equal_across_all_six_frozen_tasks,
          quantities: [:within_runtime_lift, :cross_runtime_difference_in_differences],
          reduce_order: :task_mean_per_seed_then_report_three_seed_values_and_arithmetic_mean,
          post_outcome_task_removal: false
        },
        operational_outcomes: [:calls, :cost, :latency, :parse_and_runtime_failures],
        heterogeneous_task_macro_average_is_secondary: true,
        private_universal_victory_threshold: false,
        task_removal_after_outcomes: false,
        continuation_based_on_interim_scores: false
      }
    }
  end

  defp fixed_seed_values!(opts) do
    case Keyword.fetch(opts, :seed_values) do
      {:ok, values} ->
        unless is_list(values) and values != [] and Enum.all?(values, &is_integer/1) and
                 length(Enum.uniq(values)) == length(values) do
          raise ArgumentError, "study seed_values must be a nonempty list of unique integers"
        end

        case Keyword.fetch(opts, :seeds) do
          {:ok, count} when count != length(values) ->
            raise ArgumentError, "study seeds count must equal the explicit seed_values length"

          _ ->
            values
        end

      :error ->
        count = Keyword.get(opts, :seeds, length(@fixed_seed_values))

        unless is_integer(count) and count > 0 and count <= length(@fixed_seed_values) do
          raise ArgumentError,
                "study seeds must select between 1 and #{length(@fixed_seed_values)} frozen values"
        end

        Enum.take(@fixed_seed_values, count)
    end
  end

  defp family_plan!(dataset_root, family) do
    %{spec: spec} = GepaSuite.load!(dataset_root, family)
    shape = Map.fetch!(@family_shape, family)
    train = get_in(spec, ["split_counts", "train"])
    dev = get_in(spec, ["split_counts", "dev"])
    test = get_in(spec, ["split_counts", "test"])
    mipro_metric_calls = Map.fetch!(spec, "metric_calls")

    gepa =
      dev
      |> GEPA.v014_budget_envelope(3, mipro_metric_calls)
      |> Map.put(:semantic_metric_calls, mipro_metric_calls)

    program_evaluations =
      test + mipro_metric_calls + test + gepa.max_metric_calls + test

    task_transports = legal_task_transports(program_evaluations, shape.task_stages)

    judge_transports =
      baseline_judge_transports(family, test, shape) +
        mipro_judge_transports(family, mipro_metric_calls + test, shape) +
        gepa_judge_transports(family, gepa, test, shape, :legal)

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
          baseline_judge_transports(family, test, shape),
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
          mipro_judge_transports(family, mipro_metric_calls + test, shape),
          mipro_proposer_transports,
          0
        ),
      gepa_v0_1_4_merge:
        arm_totals(
          gepa.max_metric_calls + test,
          legal_task_transports(
            gepa.max_metric_calls + test + @fresh_examples_per_selected_arm,
            shape.task_stages
          ),
          gepa_judge_transports(family, gepa, test, shape, :legal),
          0,
          gepa.max_reflection_calls
        )
    }

    nominal_arms = %{
      baseline:
        arm_totals(
          test,
          test * shape.task_stages,
          baseline_judge_transports(family, test, shape),
          0,
          0
        ),
      mipro_v2_heavy:
        arm_totals(
          mipro_metric_calls + test,
          (mipro_metric_calls + test + @fresh_examples_per_selected_arm) * shape.task_stages,
          mipro_judge_transports(family, mipro_metric_calls + test, shape),
          mipro_proposer_transports,
          0
        ),
      gepa_v0_1_4_merge:
        arm_totals(
          mipro_metric_calls + test,
          (mipro_metric_calls + test + @fresh_examples_per_selected_arm) * shape.task_stages,
          gepa_judge_transports(family, gepa, test, shape, :nominal),
          0,
          gepa.max_iterations
        )
    }

    nominal_transports =
      nominal_arms
      |> Map.values()
      |> Enum.reduce(zero_totals(), &add_totals/2)

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
      nominal_transports: nominal_transports,
      fresh: %{
        program_evaluations: fresh_program_evaluations,
        task_transports: fresh_task_transports
      },
      gepa: %{
        semantic_metric_calls: mipro_metric_calls,
        legal_metric_calls: gepa.max_metric_calls,
        logical_iterations: gepa.max_iterations,
        legal_reflection_transports: gepa.max_reflection_calls,
        judge_schedule: gepa_judge_schedule(family, gepa, test, shape)
      },
      mipro: %{
        auto: :heavy,
        instruction_candidates: @mipro_heavy_instruction_candidates,
        dataset_summary_calls: summary_calls,
        legal_proposer_transports: mipro_proposer_transports
      },
      arms: arms,
      nominal_arms: nominal_arms
    }
  end

  defp legal_task_transports(program_evaluations, task_stages) do
    program_evaluations * task_stages * @chat_json_fallback_transport_factor
  end

  defp baseline_judge_transports(_family, program_evaluations, shape),
    do: program_evaluations * shape.judge_stages

  defp mipro_judge_transports(_family, program_evaluations, shape),
    do: program_evaluations * shape.judge_stages

  # The pinned Papillon GEPA wrapper calls the three-judge overall metric and the
  # three-judge feedback metric for every optimizer evaluation. For a captured
  # parent minibatch, GEPA's component feedback callback invokes that wrapper a
  # second time. Held-out evaluation uses the ordinary three-judge metric once.
  defp gepa_judge_transports("Papillon", gepa, test, _shape, mode) do
    optimizer_calls =
      if mode == :legal, do: gepa.max_metric_calls, else: gepa.semantic_metric_calls

    traced_calls = min(optimizer_calls, gepa.max_iterations * 3)
    untraced_calls = optimizer_calls - traced_calls
    traced_calls * 12 + untraced_calls * 6 + test * 3
  end

  defp gepa_judge_transports(_family, gepa, test, shape, mode) do
    optimizer_calls =
      if mode == :legal, do: gepa.max_metric_calls, else: gepa.semantic_metric_calls

    (optimizer_calls + test) * shape.judge_stages
  end

  defp gepa_judge_schedule("Papillon", gepa, test, _shape) do
    legal_traced = min(gepa.max_metric_calls, gepa.max_iterations * 3)
    nominal_traced = min(gepa.semantic_metric_calls, gepa.max_iterations * 3)

    %{
      ordinary_judges_per_evaluation: 3,
      optimizer_untraced_judges_per_evaluation: 6,
      optimizer_traced_judges_per_evaluation: 12,
      nominal_traced_evaluations: nominal_traced,
      nominal_untraced_evaluations: gepa.semantic_metric_calls - nominal_traced,
      legal_traced_evaluations: legal_traced,
      legal_untraced_evaluations: gepa.max_metric_calls - legal_traced,
      heldout_evaluations: test
    }
  end

  defp gepa_judge_schedule(_family, _gepa, _test, _shape), do: :ordinary_metric_once

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
    sum_family_arms(families, :arms)
  end

  defp sum_family_arms(families, key) do
    Enum.reduce(families, %{}, fn family, arms ->
      Map.merge(arms, Map.fetch!(family, key), fn _arm, left, right ->
        add_totals(left, right)
      end)
    end)
  end

  defp sum_family_totals(families, key) do
    Enum.reduce(families, zero_totals(), fn family, totals ->
      add_totals(totals, Map.fetch!(family, key))
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
