defmodule Imp.BenchmarkTruth.LangProBeHeartDiseaseMiproCurrent do
  @moduledoc false

  alias Imp.BenchmarkTruth.LangProBeHeartDisease, as: Heart
  alias Imp.Optimizer.MIPROv2

  @condition "imp-88sn-langprobe-heart-disease-mipro-current-v1"
  @seeds [2_026_080_201, 2_026_080_202, 2_026_080_203, 2_026_080_204, 2_026_080_205]
  @program_grounding "Four sequential LM calls: three independent trainee opinions over the same 13 Heart Disease fields, followed by one vote over those fields and the three rendered opinions."

  def condition, do: @condition
  def seeds, do: @seeds
  def status, do: :provider_free_preregistration_in_progress
  def program_grounding, do: @program_grounding

  def study_identity do
    %{
      kind: :adapted_current_source_matched_comparison,
      not_claimed: [:exact_mipro_paper_reproduction, :clinical_validation, :broad_superiority],
      authorities: Heart.authority(),
      split: Heart.data!().receipt["authority"]
    }
  end

  def historical_context do
    %{
      authority_commit: "f0061917f0e33ad141013d720c2ddea89c245da9",
      result_path: "experiment_data/20250305/gpt4o_0305.csv",
      result_sha256: "d1952622f5bb3050601535c69121547727a5540648885f45114dca6ea4cad14a",
      runtime: :dspy,
      model: :gpt_4o,
      program: :cot_based_vote,
      baseline_test_accuracy: 0.6316,
      mipro_test_accuracy: 0.6842,
      mipro_lift: 0.0526,
      recorded_optimizer_cost_usd: 71.10282250000006,
      scope: :single_historical_run_context_not_acceptance_standard
    }
  end

  def acceptance do
    %{
      runs_per_runtime: 5,
      primary_estimand: :mean_selected_test_accuracy_imp_minus_dspy,
      own_baseline_lifts_reported: true,
      matched_test_rows: 152,
      per_example_run_aggregation: :mean,
      test: :two_sided_wilcoxon_signed_rank,
      alpha: 0.05,
      classification: %{
        imp_superior: :positive_effect_and_p_below_alpha,
        dspy_superior: :negative_effect_and_p_below_alpha,
        otherwise: :inconclusive
      },
      uncertainty: :paired_per_example_bootstrap_95_percent_interval,
      artifact_and_fresh_service_required_every_run: true,
      prohibited_shortcuts: [:seed_stopping, :result_conditioned_comparator, :threshold_rewrite]
    }
  end

  def adapter_semantics do
    %{
      imp: %{adapter: Imp.Adapter.Chat, json_fallback: false},
      dspy: %{
        adapter: "DSPy 3.2.1 ChatAdapter",
        use_json_adapter_fallback: false
      },
      reason: :one_strict_marker_transport_per_scheduled_stage
    }
  end

  def routes do
    %{
      observed_at: "2026-08-01",
      task: %{
        model: "deepseek/deepseek-v4-flash-0731",
        endpoint_model: "deepseek/deepseek-v4-flash-20260731",
        provider_candidate: "siliconflow/fp8",
        input_price_per_million: 0.14,
        output_price_per_million: 0.28,
        max_tokens: 512
      },
      proposer: %{
        model: "qwen/qwen3.7-max",
        endpoint_model: "qwen/qwen3.7-max-20260520",
        provider_candidate: "alibaba/fp8",
        input_price_per_million: 1.475,
        output_price_per_million: 4.425,
        max_tokens: 4_096
      },
      admission: :current_catalog_route_privacy_and_price_preflight_required
    }
  end

  def provider_free_census do
    %{
      imp: %{
        task: %{calls: 14_544, max_bytes: 5_462, p95_bytes: 4_616},
        proposer: %{calls: 147, max_bytes: 5_165, p95_bytes: 4_278}
      },
      dspy: %{
        task: %{calls: 14_544, max_bytes: 6_187, p95_bytes: 5_341},
        proposer: %{calls: 147, max_bytes: 10_927, p95_bytes: 10_881}
      },
      scope: :planted_outputs_all_c12_demo_arms_all_303_rows_not_live_output_bound
    }
  end

  def planning_reservation do
    plan = call_plan().study
    task = routes().task
    proposer = routes().proposer
    task_input_bytes = 16_384 + 1_024
    proposer_input_bytes = 65_536 + 4_096

    task_input =
      plan.task * task_input_bytes / 1_000_000 * task.input_price_per_million

    task_output = plan.task * task.max_tokens / 1_000_000 * task.output_price_per_million

    proposer_input =
      plan.proposer * proposer_input_bytes / 1_000_000 * proposer.input_price_per_million

    proposer_output =
      plan.proposer * proposer.max_tokens / 1_000_000 * proposer.output_price_per_million

    %{
      status: :planning_only_not_legal_ceiling,
      proposed_content_guards: %{task: 16_384, proposer: 65_536},
      explicit_framing_reservations: %{task: 1_024, proposer: 4_096},
      task_input_usd: task_input,
      task_output_usd: task_output,
      proposer_input_usd: proposer_input,
      proposer_output_usd: proposer_output,
      total_usd: task_input + task_output + proposer_input + proposer_output,
      provider_cache_discount_assumed: false,
      owner_spend_authority: :not_granted
    }
  end

  def call_plan do
    schedule = MIPROv2.upstream_trial_schedule(50, 5)
    promoted = length(schedule.periodic_full_evaluations)

    task = %{
      bootstrap_legal: 10 * 15 * 4,
      optimizer_baseline: 136 * 4,
      minibatch_objectives: 50 * 35 * 4,
      periodic_full_evaluations: promoted * 136 * 4,
      outer_baseline_and_optimized_selection: 2 * 136 * 4,
      outer_baseline_and_selected_test: 2 * 152 * 4,
      fresh_service: 4 * 4
    }

    proposer = %{
      dataset_grounding: 3,
      program_aware_candidates: 12 * 4 * 3
    }

    per_runtime_run = %{
      task: Enum.sum(Map.values(task)),
      proposer: Enum.sum(Map.values(proposer))
    }

    %{
      executable: false,
      remaining_evidence: [
        :live_generated_values_fit_enforced_guards_without_changing_opportunity,
        :exact_route_single_transport_and_privacy_preflight,
        :turn_planning_guards_into_both_runtime_pretransport_enforcement,
        :legal_cost_ceiling_and_owner_spend_disposition
      ],
      task: task,
      proposer: proposer,
      per_runtime_run: per_runtime_run,
      study: %{
        task: per_runtime_run.task * 2 * length(@seeds),
        proposer: per_runtime_run.proposer * 2 * length(@seeds)
      },
      full_opportunity_claimed: false
    }
  end

  def proposer_prompt_census!(calls) when is_list(calls) and calls != [] do
    rendered =
      Enum.map(calls, fn messages ->
        messages
        |> Enum.map(&%{role: &1.role, content: &1.content})
        |> Jason.encode!()
      end)

    sizes = rendered |> Enum.map(&byte_size/1) |> Enum.sort()

    %{
      calls: length(rendered),
      min_bytes: hd(sizes),
      p95_bytes: percentile(sizes, 0.95),
      max_bytes: List.last(sizes),
      ordered_sha256: sha256(IO.iodata_to_binary(rendered))
    }
  end

  def task_prompt_census!(search_demos) when is_map(search_demos) do
    data = Heart.data!()
    examples = data.train ++ data.selection ++ data.test

    predictors =
      Heart.new(Imp.LM.Static.new(handler: fn _, _ -> %{} end))
      |> Imp.ProgramParameters.predictors()

    rendered =
      for item <- predictors,
          demos <- Map.fetch!(search_demos, item.name),
          example <- examples do
        inputs =
          example
          |> Imp.Example.inputs()
          |> Imp.Example.to_map()
          |> maybe_add_vote_context(item.name)

        Imp.Adapter.Chat.format(item.predictor.signature, inputs, demos: demos)
        |> Enum.map(&%{role: &1.role, content: &1.content})
        |> Jason.encode!()
      end

    sizes = rendered |> Enum.map(&byte_size/1) |> Enum.sort()

    %{
      source: :actual_pinned_search_demo_arms,
      calls: length(rendered),
      demo_arm_sizes:
        Map.new(predictors, fn item ->
          {item.name, Enum.map(Map.fetch!(search_demos, item.name), &length/1)}
        end),
      min_bytes: hd(sizes),
      p95_bytes: percentile(sizes, 0.95),
      max_bytes: List.last(sizes),
      ordered_sha256: sha256(IO.iodata_to_binary(rendered))
    }
  end

  def program(lm), do: Heart.new(lm)
  def metric(expected, prediction), do: Heart.metric(expected, prediction)

  def optimizer(task_lm, prompt_lm, seed) when seed in @seeds do
    MIPROv2.new(&metric/2,
      auto: nil,
      num_candidates: 12,
      num_trials: 50,
      startup_trials: 10,
      max_bootstrapped_demos: 4,
      max_labeled_demos: 2,
      minibatch: true,
      minibatch_size: 35,
      minibatch_full_eval_steps: 5,
      proposer_fidelity: :dspy_3_2_1,
      search_fidelity: :dspy_3_2_1_optuna_4_9_0,
      program_aware_proposer: true,
      program_grounding: {:text, @program_grounding},
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: true,
      view_data_batch_size: 10,
      prompt_lm: prompt_lm,
      task_lm: task_lm,
      max_errors: 10,
      max_concurrency: 1,
      metric_identity: %{
        "id" => "langprobe-heart-disease-accuracy",
        "version" => 1,
        "config" => %{}
      },
      seed: seed
    )
  end

  def experiment_options do
    [
      artifact_id: @condition <> "-selected",
      metric_identity: %{"kind" => "accuracy", "version" => 1},
      compare_baseline_on_test: true,
      evaluation_options: [
        repetitions: 1,
        aggregation: :mean,
        max_errors: 10,
        failure_score: 0.0,
        max_concurrency: 1
      ]
    ]
  end

  defp maybe_add_vote_context(inputs, :vote) do
    opinion =
      "I'm a trainee doctor, trying to provider-free clinical reasoning. Hence, my answer is no."

    Map.put(inputs, :context, List.duplicate(opinion, 3))
  end

  defp maybe_add_vote_context(inputs, _name), do: inputs

  defp percentile(sorted, percentile) do
    index = max(0, ceil(length(sorted) * percentile) - 1)
    Enum.at(sorted, index)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
