defmodule Imp.BenchmarkTruth.MusiqueAnsMiproCurrent do
  @moduledoc false

  alias Imp.BenchmarkTruth.MusiqueAns
  alias Imp.Optimizer.MIPROv2

  @condition "imp-88sn-musique-ans-mipro-current-v1"
  @receipt "benchmarks/data/musique-ans-mipro-current-v1.receipt.json"
  @receipt_sha "df91cf92c123bdaab3dca9943dd0d47188498d4d99488bad9bc215ecd66d7b36"
  @seeds [2_026_080_201, 2_026_080_202, 2_026_080_203]
  @program_grounding "MuSiQue adapted LM Select-to-Answer: selector ranks exactly seven original paragraph indices; answerer returns an answer and unique supporting positions within those seven; positions map back to original indices."
  @dynamic_output_allowance 8_192
  @task_input_guard 52_744
  @proposer_input_guard 149_443

  def condition, do: @condition
  def status, do: :provider_free_readiness_in_progress
  def seeds, do: @seeds
  def receipt_path, do: @receipt
  def program_grounding, do: @program_grounding

  def prompt_guards do
    %{
      task: %{
        max_input_bytes: @task_input_guard,
        max_output_tokens: routes().task.max_tokens,
        basis: :actual_search_artifact_census_plus_dynamic_instruction_allowance
      },
      proposer: %{
        max_input_bytes: @proposer_input_guard,
        max_output_tokens: routes().proposer.max_tokens,
        observed_max_bytes: 124_867,
        dynamic_input_allowances: 3,
        dynamic_value_max_bytes: @dynamic_output_allowance,
        basis: :exact_47_call_setup_census_plus_three_dynamic_inputs
      }
    }
  end

  def adapter_semantics do
    %{
      imp_task: %{adapter: Imp.Adapter.JSON, json_repair: false, json_fallback: false},
      dspy_task: %{
        adapter: "DSPy 3.2.1 JSONAdapter",
        json_repair: true,
        chat_formatted_retry_on_adapter_error: false,
        structured_schema_to_json_object_fallback: true,
        exact_route_single_transport: :unverified
      },
      proposer: :runtime_native_text_chat
    }
  end

  def admit_dynamic_value!(kind, value)
      when kind in [:dataset_summary, :program_description, :module_description, :instruction] and
             is_binary(value) do
    if byte_size(value) > @dynamic_output_allowance do
      raise Imp.OperationalSafetyError,
        kind: :budget,
        message: "MuSiQue #{kind} exceeds the frozen dynamic-value byte guard",
        reason: %{
          field: kind,
          actual_bytes: byte_size(value),
          max_bytes: @dynamic_output_allowance
        }
    end

    value
  end

  def acceptance do
    %{
      primary: :mean_answer_support_f1,
      aggregate: :mean,
      minimum_mean_lift: 0.05,
      minimum_positive_seeds: 2,
      seed_count: 3,
      component_floors: %{mean_answer_f1_lift: 0.0, mean_support_f1_lift: 0.0},
      secondary: :exact_match,
      artifact_required: true,
      fresh_service_calls_per_seed: 4,
      reporting: %{
        every_seed_and_component: true,
        per_hop: [:answer_f1, :support_f1, :joint_adapted, :exact_match],
        parameter_identical_baseline_causal_lift: 0.0,
        joint_metric_scope: :adapted_not_official,
        prohibited_claims: [:broad_mipro_effectiveness, :modeled_tpe_causation]
      },
      evidence_scope: :official_source_row_disjoint_treatment_unseen_semantic_overlap_disclosed
    }
  end

  def routes do
    %{
      task: %{
        model: "deepseek/deepseek-v4-flash-0731",
        endpoint_model: "deepseek/deepseek-v4-flash-20260731",
        snapshot: "20260731",
        provider: "siliconflow/fp8",
        input_price_per_million: 0.14,
        output_price_per_million: 0.28,
        reasoning: :none,
        temperature: 1.0,
        top_p: 1.0,
        max_tokens: 512
      },
      proposer: %{
        model: "anthropic/claude-sonnet-5",
        endpoint_model: "anthropic/claude-sonnet-5-20260630",
        snapshot: "20260630",
        provider: "google-vertex/global",
        input_price_per_million: 2.0,
        output_price_per_million: 10.0,
        reasoning: :high,
        max_tokens: 4_096,
        omitted: [:temperature, :top_p, :verbosity]
      },
      policy: %{
        zdr: true,
        data_collection: :deny,
        only_order: true,
        fallback: false,
        retries: 0,
        cache: false,
        provider_prompt_cache: :measured_not_assumed
      }
    }
  end

  def provider_preferences(role) when role in [:task, :proposer] do
    route = Map.fetch!(routes(), role)

    %{
      only: [route.provider],
      order: [route.provider],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      zdr: true
    }
  end

  def route_lm(role, opts \\ []) when role in [:task, :proposer] do
    route = Map.fetch!(routes(), role)

    max_input_bytes =
      Keyword.get(opts, :max_input_bytes, Map.fetch!(prompt_guards(), role).max_input_bytes)

    api_key = Keyword.get(opts, :api_key, System.get_env("OPENROUTER_API_KEY"))
    req_http_options = Keyword.get(opts, :req_http_options, retry: false, max_retries: 0)

    role_options =
      case role do
        :task ->
          [
            temperature: route.temperature,
            top_p: route.top_p,
            openrouter_reasoning: %{effort: :none}
          ]

        :proposer ->
          [openrouter_reasoning: %{effort: :high}]
      end

    Imp.req_llm(
      %{
        provider: :openrouter,
        id: route.model,
        model: route.model,
        base_url: "https://openrouter.ai/api/v1"
      },
      [
        api_key: api_key,
        cache: false,
        max_tokens: route.max_tokens,
        max_retries: 0,
        input_envelope: [max_bytes: max_input_bytes, reservation_tokens: max_input_bytes],
        provider_options: [
          openrouter_provider: provider_preferences(role),
          openrouter_usage: %{include: true}
        ],
        req_http_options:
          Keyword.update(req_http_options, :headers, openrouter_headers(), fn headers ->
            openrouter_headers() ++ headers
          end)
      ] ++ role_options
    )
  end

  def call_plan do
    schedule = MIPROv2.upstream_trial_schedule(40, 5)
    full = length(schedule.periodic_full_evaluations)

    task = %{
      bootstrap: 4 * 700 * 2,
      optimizer_baseline: 300 * 2,
      minibatch_objectives: 40 * 35 * 2,
      periodic_full_evaluations: full * 300 * 2,
      outer_selection: 2 * 3 * 300 * 2,
      outer_dev: 2 * 3 * 2_417 * 2,
      fresh_service: 4 * 2
    }

    proposer = %{dataset_grounding: 11, program_aware_candidates: 6 * 2 * 3}

    plan = %{
      executable: false,
      remaining_evidence: [
        :pinned_upstream_complete_census_exact_route_single_transport_and_pretransport_guards,
        :task_owned_wire_framing_and_dynamic_output_guard_wiring_including_bootstrap_demos,
        :current_catalog_revalidation_and_owner_spend_cap
      ],
      per_runtime_seed: %{
        task: Enum.sum(Map.values(task)),
        proposer: Enum.sum(Map.values(proposer))
      },
      task: task,
      proposer: proposer,
      study: %{task: 278_472, proposer: 282}
    }

    Map.put(plan, :reservation, reservation(plan.study))
  end

  def reservation(%{task: task_calls, proposer: proposer_calls}) do
    task = routes().task
    proposer = routes().proposer
    guards = prompt_guards()

    task_input =
      task_calls * guards.task.max_input_bytes / 1_000_000 * task.input_price_per_million

    task_output = task_calls * task.max_tokens / 1_000_000 * task.output_price_per_million

    proposer_input =
      proposer_calls * guards.proposer.max_input_bytes / 1_000_000 *
        proposer.input_price_per_million

    proposer_output =
      proposer_calls * proposer.max_tokens / 1_000_000 * proposer.output_price_per_million

    %{
      accounting: :full_price_byte_as_token_planning_arithmetic,
      task_input_usd: task_input,
      task_output_usd: task_output,
      proposer_input_usd: proposer_input,
      proposer_output_usd: proposer_output,
      total_usd: task_input + task_output + proposer_input + proposer_output,
      owner_spend_authority: :not_granted,
      current_catalog_revalidation_required: true,
      provider_prompt_cache_discount_assumed: false
    }
  end

  def receipt! do
    bytes = File.read!(@receipt)
    if sha256(bytes) != @receipt_sha, do: raise("MuSiQue frozen receipt drift")
    receipt = Jason.decode!(bytes)
    true = receipt["condition"] == @condition

    true =
      Enum.map(receipt["splits"]["train"], & &1["hop"]) |> Enum.frequencies() == %{
        2 => 505,
        3 => 154,
        4 => 41
      }

    true =
      Enum.map(receipt["splits"]["selection"], & &1["hop"]) |> Enum.frequencies() == %{
        2 => 216,
        3 => 66,
        4 => 18
      }

    receipt
  end

  def data!(data_root) do
    receipt = receipt!()
    source = receipt["source"]

    rows =
      data_root
      |> Path.join("musique_ans_v1.0_train.jsonl")
      |> read_rows_with_sha!(source["train_sha256"])

    dev =
      data_root
      |> Path.join("musique_ans_v1.0_dev.jsonl")
      |> read_rows_with_sha!(source["dev_sha256"])

    if length(rows) != source["train_rows"], do: raise("MuSiQue train row-count drift")

    for split <- ["train", "selection"] do
      digest =
        receipt["splits"][split]
        |> Enum.map_join("", &(&1["row_sha256"] <> "\n"))
        |> sha256()

      if digest != receipt["ordered_split_sha256"][split],
        do: raise("MuSiQue ordered #{split} split drift")
    end

    build = fn split ->
      Enum.map(receipt["splits"][split], fn item ->
        row = Enum.at(rows, item["source_index"])

        if row["id"] != item["id"] or sha256(canonical(row)) != item["row_sha256"],
          do: raise("MuSiQue frozen row drift")

        MusiqueAns.example(row)
      end)
    end

    Imp.Experiment.Data.new(
      train: build.("train"),
      selection: build.("selection"),
      test: Enum.map(dev, &MusiqueAns.example/1),
      id: :id
    )
  end

  def program(lm),
    do:
      MusiqueAns.new(lm,
        adapter: Imp.Adapter.JSON,
        config: [response_format: %{type: "json_object"}, cache: false, json_fallback: false]
      )

  def metric(example, prediction) do
    score = MusiqueAns.score(example, prediction)
    (score.answer_f1 + score.support_f1) / 2
  end

  def optimizer(task_lm, prompt_lm, seed) when seed in @seeds do
    MIPROv2.new(&metric/2,
      auto: nil,
      num_candidates: 6,
      num_trials: 40,
      startup_trials: 10,
      max_bootstrapped_demos: 2,
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
        "id" => "musique-adapted-mean-answer-support-f1",
        "version" => 1,
        "config" => %{"answer_weight" => 0.5, "support_weight" => 0.5}
      },
      seed: seed
    )
  end

  def experiment_options do
    [
      artifact_id: @condition <> "-selected",
      metric_identity: %{"kind" => "mean_answer_support_f1", "version" => 1},
      compare_baseline_on_test: true,
      evaluation_options: [
        repetitions: 3,
        aggregation: :mean,
        max_errors: 10,
        failure_score: 0.0,
        max_concurrency: 1
      ]
    ]
  end

  def task_prompt_census!(data_root, search_demos) when is_map(search_demos) do
    data = data!(data_root)
    examples = data.train ++ data.selection ++ data.test
    probe = program(Imp.LM.Static.new(handler: fn _, _ -> %{} end))
    selector_arms = Map.fetch!(search_demos, :selector)
    answerer_arms = Map.fetch!(search_demos, :answerer)

    selector_max =
      for ex <- examples,
          demos <- selector_arms,
          reduce: 0 do
        maximum ->
          bytes =
            adapter_bytes(
              probe.selector.signature,
              %{
                question: Imp.Example.get(ex, :question),
                paragraphs: Imp.Example.get(ex, :paragraphs)
              },
              demos
            )

          max(maximum, bytes)
      end

    answerer_max =
      for ex <- examples,
          demos <- answerer_arms,
          reduce: 0 do
        maximum ->
          bytes = adapter_bytes(probe.answerer.signature, answerer_census_inputs(ex), demos)
          max(maximum, bytes)
      end

    %{
      source: :actual_pinned_search_demo_arms,
      selector_demo_arm_sizes: Enum.map(selector_arms, &length/1),
      answerer_demo_arm_sizes: Enum.map(answerer_arms, &length/1),
      selector_max_bytes: selector_max,
      answerer_max_bytes: answerer_max,
      selector_guard_bytes: selector_max + 8_192,
      answerer_guard_bytes: answerer_max + 8_192,
      dynamic_output_allowance_bytes: 8_192,
      dev_labels_used: false
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
      p50_bytes: percentile(sizes, 0.50),
      p95_bytes: percentile(sizes, 0.95),
      max_bytes: List.last(sizes),
      ordered_sha256: sha256(IO.iodata_to_binary(rendered))
    }
  end

  defp read_rows_with_sha!(path, expected_sha) do
    bytes = File.read!(path)

    if sha256(bytes) != expected_sha,
      do: raise("MuSiQue source file drift: #{Path.basename(path)}")

    bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp answerer_census_inputs(ex) do
    selected =
      ex
      |> Imp.Example.get(:paragraphs)
      |> Enum.sort_by(&byte_size(Jason.encode!(&1)), :desc)
      |> Enum.take(7)

    %{
      question: Imp.Example.get(ex, :question),
      selected_paragraphs: selected
    }
  end

  defp adapter_bytes(signature, inputs, demos),
    do:
      Imp.Adapter.JSON.format(signature, inputs, demos: demos)
      |> Enum.map(&%{role: &1.role, content: &1.content})
      |> Jason.encode!()
      |> byte_size()

  defp canonical(value), do: Jason.encode!(value, maps: :strict)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp percentile(sorted, percentile) do
    index = max(0, ceil(length(sorted) * percentile) - 1)
    Enum.at(sorted, index)
  end

  defp openrouter_headers,
    do: [{"X-OpenRouter-Metadata", "enabled"}, {"X-OpenRouter-Cache", "false"}]
end
