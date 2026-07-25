defmodule Imp.BenchmarkTruth.SupportTicketLiftCampaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{BudgetedLM, CampaignBudget, OpenRouterFreeGuard}
  alias Imp.Optimizer.LabeledFewShot

  @seeds [17, 23, 31]
  @arms [:baseline, :labeled_few_shot]
  @test_limit 8
  @balanced_test_indices [0, 1, 5, 6, 10, 11, 15, 16]
  @v1_max_output_tokens 64
  @v2_max_output_tokens 256
  @v2_campaign_id "support-ticket-baseline-vs-labeled-few-shot-openrouter-free-v2"
  @expected_requests length(@seeds) * length(@arms) * @test_limit

  def run(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    validate_runtime!(runtime)
    seeds = Keyword.get(opts, :seeds, @seeds)
    arms = Keyword.get(opts, :arms, @arms)
    test_limit = Keyword.get(opts, :test_limit, @test_limit)
    campaign = Keyword.get(opts, :campaign, "support-ticket-baseline-vs-labeled-few-shot")
    max_output_tokens = Keyword.get(opts, :max_output_tokens, @v1_max_output_tokens)
    validate_design!(seeds, arms, test_limit, runtime, campaign, max_output_tokens)

    dataset_path =
      opts
      |> Keyword.get(
        :dataset_path,
        Application.app_dir(:imp, "priv/tutorial/support_tickets.json")
      )
      |> Path.expand()

    {dataset, dataset_meta} = load_dataset!(dataset_path, test_limit)
    request_limit = length(seeds) * length(arms) * test_limit

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          requests: request_limit,
          input_tokens: 2_000_000,
          output_tokens: request_limit * max_output_tokens,
          usd: 0.0
        },
        pricing: %{"input_per_million" => 0.0, "output_per_million" => 0.0},
        default_max_output_tokens: max_output_tokens
      )

    telemetry_id = CampaignBudget.attach_req_llm(budget)
    {ledger, catalog} = runtime_state(runtime, opts)

    lm_factory =
      Keyword.get(opts, :lm_factory, default_lm_factory(runtime, opts, max_output_tokens))

    context = %{
      runtime: runtime,
      strict?: runtime == :openrouter_free or Keyword.get(opts, :strict_failure_capture, false),
      dataset: dataset,
      dataset_meta: dataset_meta,
      seeds: seeds,
      arms: arms,
      test_limit: test_limit,
      request_limit: request_limit,
      campaign: campaign,
      protocol_manifest: Keyword.get(opts, :protocol_manifest),
      max_output_tokens: max_output_tokens,
      budget: budget,
      ledger: ledger,
      catalog: catalog,
      lm_factory: lm_factory,
      model: model_name(runtime, opts),
      model_metadata: Keyword.get(opts, :model_metadata, %{})
    }

    try do
      results = run_schedule(context)
      artifact(context, results)
    after
      :telemetry.detach(telemetry_id)
    end
  end

  def expected_requests, do: @expected_requests

  def v2_options!(path) do
    path = Path.expand(path)
    bytes = File.read!(path)
    manifest = Jason.decode!(bytes)
    validate_v2_manifest!(manifest)

    [
      campaign: @v2_campaign_id,
      max_output_tokens: @v2_max_output_tokens,
      protocol_manifest: %{
        "path" => path,
        "sha256" => sha256(bytes),
        "status_at_launch" => manifest["status"]
      }
    ]
  end

  defp run_schedule(context) do
    schedule = for seed <- context.seeds, arm <- context.arms, do: {seed, arm}

    Enum.reduce_while(schedule, [], fn {seed, arm}, rows ->
      row = run_arm(context, seed, arm)
      rows = rows ++ [row]

      if context.strict? and row["status"] != "completed",
        do: {:halt, rows},
        else: {:cont, rows}
    end)
  end

  defp run_arm(context, seed, arm) do
    before = CampaignBudget.snapshot(context.budget)
    lm = context.lm_factory.(seed, context.budget, context.ledger)
    program = base_program(lm)
    started = System.monotonic_time(:millisecond)

    try do
      compiled = compile_arm(arm, program, context.dataset.train, seed)

      if context.strict?, do: assert_ledger_open!(context.ledger)

      evaluation =
        Imp.evaluate(
          compiled,
          context.dataset.test,
          Imp.exact_match(:team),
          max_concurrency: 1,
          max_errors: if(context.strict?, do: 1, else: :infinity),
          timeout: 120_000
        )

      if evaluation.errors != [] and context.strict? do
        raise "strict provider evaluation returned #{length(evaluation.errors)} malformed rows"
      end

      after_snapshot = CampaignBudget.snapshot(context.budget)

      %{
        "seed" => seed,
        "arm" => Atom.to_string(arm),
        "status" => "completed",
        "selection_split" => selection_split(arm),
        "test_score" => evaluation.score,
        "test_rows" =>
          Enum.map(evaluation.rows, fn row ->
            %{
              "index" => row.index,
              "score" => row.score,
              "error" => row.error && safe_error(row.error),
              "response" => response_accounting(row.prediction)
            }
          end),
        "test_errors" => Enum.map(evaluation.errors, &safe_error/1),
        "program" => program_summary(compiled),
        "budget_delta" => budget_delta(before, after_snapshot),
        "wall_seconds" => elapsed_seconds(started)
      }
    rescue
      error -> failure_row(context, seed, arm, before, started, error, __STACKTRACE__)
    catch
      kind, reason -> failure_row(context, seed, arm, before, started, {kind, reason}, [])
    end
  end

  defp base_program(lm) do
    "ticket -> team: enum[atlas,harbor,beacon,quill]"
    |> Imp.signature(
      "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
    )
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 0])
  end

  defp compile_arm(:baseline, program, _trainset, _seed), do: program

  defp compile_arm(:labeled_few_shot, program, trainset, seed) do
    Imp.optimize!(program, LabeledFewShot.new(k: 8, sample: true, seed: seed), trainset)
  end

  defp selection_split(:baseline), do: "none"
  defp selection_split(:labeled_few_shot), do: "train"

  defp failure_row(context, seed, arm, before, started, error, stacktrace) do
    after_snapshot = CampaignBudget.snapshot(context.budget)

    %{
      "seed" => seed,
      "arm" => Atom.to_string(arm),
      "status" => "failed",
      "selection_split" => selection_split(arm),
      "test_score" => nil,
      "test_rows" => [],
      "test_errors" => failure_messages(error, stacktrace),
      "failure_detail" => failure_detail(error, stacktrace),
      "provider_failure_context" => last_provider_response(context),
      "program" => nil,
      "budget_delta" => budget_delta(before, after_snapshot),
      "wall_seconds" => elapsed_seconds(started)
    }
  end

  defp artifact(context, results) do
    budget = CampaignBudget.snapshot(context.budget)
    completed? = length(results) == length(context.seeds) * length(context.arms)
    no_failures? = Enum.all?(results, &(&1["status"] == "completed"))

    %{
      "schema_version" => 1,
      "campaign" => context.campaign,
      "protocol_manifest" => context.protocol_manifest,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "runtime" => Atom.to_string(context.runtime),
      "model" => context.model,
      "model_metadata" => context.model_metadata,
      "seeds" => context.seeds,
      "arms" => Enum.map(context.arms, &Atom.to_string/1),
      "dataset" => context.dataset_meta,
      "controls" => %{
        "train_visible_to_optimizer" => true,
        "selection_visible_to_optimizer" => false,
        "test_visible_to_optimizer_or_selection" => false,
        "test_opened_only_after_each_program_was_compiled" => true,
        "same_test_rows_and_generation_limits_for_every_arm_seed" => true,
        "cache" => false,
        "max_concurrency" => 1,
        "max_output_tokens" => context.max_output_tokens,
        "json_retries" => 0,
        "transport_retries" => 0,
        "logical_request_limit" => context.request_limit
      },
      "results" => results,
      "summary" => summarize(results, context.seeds, completed? and no_failures?),
      "budget" => budget,
      "provider_accounting" => provider_accounting(context),
      "scope" =>
        "A three-seed, untouched eight-row support-ticket preflight for baseline versus sampled LabeledFewShot on one model. It is not a matched upstream run, the canonical GSM8K/Banking77 portfolio, or general optimizer effectiveness evidence."
    }
  end

  defp summarize(results, seeds, complete?) do
    baseline = score_by_seed(results, "baseline")
    optimized = score_by_seed(results, "labeled_few_shot")

    paired =
      Enum.flat_map(seeds, fn seed ->
        with {:ok, base} <- Map.fetch(baseline, seed),
             {:ok, opt} <- Map.fetch(optimized, seed) do
          [%{"seed" => seed, "baseline" => base, "optimized" => opt, "lift" => opt - base}]
        else
          _ -> []
        end
      end)

    lifts = Enum.map(paired, & &1["lift"])
    ci = exact_bootstrap_interval(lifts)
    mean_lift = mean(lifts)
    improving = Enum.count(lifts, &(&1 > 0))

    numeric_go? =
      length(lifts) == length(seeds) and is_number(mean_lift) and mean_lift >= 0.03 and
        is_number(ci["lower"]) and ci["lower"] > 0 and
        improving >= 2

    failed_row = Enum.find(results, &(&1["status"] == "failed"))

    %{
      "execution_complete" => complete?,
      "paired_scores" => paired,
      "mean_test_lift" => mean_lift,
      "paired_exact_bootstrap_95_interval" => ci,
      "improving_seeds" => improving,
      "declared_seed_count" => length(seeds),
      "within_task_numeric_go_rule_passed" => numeric_go?,
      "stopped_failure" => failed_row && failed_row["failure_detail"],
      "stopped_provider_context" => failed_row && failed_row["provider_failure_context"],
      "c3_effectiveness_established" => false,
      "c3_exclusions" => [
        "no independently executed upstream comparator",
        "not the canonical GSM8K and Banking77 portfolio",
        "single task and single model",
        "eight test rows have low statistical resolution"
      ]
    }
  end

  defp score_by_seed(results, arm) do
    results
    |> Enum.filter(&(&1["arm"] == arm and is_number(&1["test_score"])))
    |> Map.new(&{&1["seed"], &1["test_score"]})
  end

  defp exact_bootstrap_interval([]), do: %{"lower" => nil, "upper" => nil}

  defp exact_bootstrap_interval(values) do
    count = length(values)

    means =
      values
      |> cartesian_repetitions(count)
      |> Enum.map(&mean/1)
      |> Enum.sort()

    %{
      "lower" => percentile(means, 0.025),
      "upper" => percentile(means, 0.975),
      "method" => "exact paired bootstrap over all n^n seed resamples"
    }
  end

  defp cartesian_repetitions(_values, 0), do: [[]]

  defp cartesian_repetitions(values, count) do
    for value <- values, rest <- cartesian_repetitions(values, count - 1), do: [value | rest]
  end

  defp percentile(values, fraction) do
    index = floor(fraction * (length(values) - 1))
    Enum.at(values, index)
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp response_accounting(%Imp.Prediction{metadata: metadata}) do
    req = Map.get(metadata, :req_llm, %{})
    usage = Map.get(req, :usage, %{}) || %{}
    provider_meta = Map.get(req, :provider_meta, %{}) || %{}

    %{
      "gateway_provider" => Map.get(req, :provider),
      "upstream_provider" => map_value(provider_meta, :provider),
      "actual_model" => Map.get(req, :model),
      "input_tokens" => map_value(usage, :input_tokens),
      "output_tokens" => map_value(usage, :output_tokens),
      "provider_reported_cost_usd" => map_value(usage, "cost"),
      "computed_cost_usd" => map_value(usage, :total_cost)
    }
  end

  defp response_accounting(_prediction), do: nil

  defp program_summary(program) do
    predictors = Imp.ProgramParameters.predictors(program)

    %{
      "predictor_count" => length(predictors),
      "demo_count" => Enum.sum(Enum.map(predictors, &length(Map.get(&1.predictor, :demos, [])))),
      "instructions_sha256" =>
        predictors
        |> Enum.map(&get_in(&1, [:predictor, Access.key(:signature), Access.key(:instructions)]))
        |> CampaignBudget.evidence_digest()
    }
  end

  defp provider_accounting(%{runtime: :openrouter_free, ledger: ledger, catalog: catalog}) do
    %{"catalog" => catalog, "response_ledger" => OpenRouterFreeGuard.ledger_snapshot(ledger)}
  end

  defp provider_accounting(_context), do: nil

  defp budget_delta(before, after_snapshot) do
    %{
      "logical_requests" => after_snapshot["requests"] - before["requests"],
      "transport_attempts" => after_snapshot["transport_attempts"] - before["transport_attempts"],
      "input_tokens" =>
        get_in(after_snapshot, ["usage", "input_tokens"]) -
          get_in(before, ["usage", "input_tokens"]),
      "output_tokens" =>
        get_in(after_snapshot, ["usage", "output_tokens"]) -
          get_in(before, ["usage", "output_tokens"]),
      "usd" => get_in(after_snapshot, ["usage", "usd"]) - get_in(before, ["usage", "usd"])
    }
  end

  defp runtime_state(:openrouter_free, opts) do
    {:ok, ledger} = OpenRouterFreeGuard.start_ledger()
    {ledger, Keyword.get_lazy(opts, :catalog, &OpenRouterFreeGuard.current_catalog!/0)}
  end

  defp runtime_state(:local, _opts), do: {nil, nil}

  defp default_lm_factory(:openrouter_free, opts, max_output_tokens) do
    api_key = Keyword.fetch!(opts, :api_key)

    fn seed, budget, ledger ->
      OpenRouterFreeGuard.strict_lm(api_key, budget, ledger, seed,
        max_output_tokens: max_output_tokens
      )
    end
  end

  defp default_lm_factory(:local, opts, max_output_tokens) do
    model = Keyword.get(opts, :model, "ollama:llama3.2:3b")
    req_model = local_req_model(model)

    fn seed, budget, _ledger ->
      inner =
        Imp.req_llm(req_model,
          temperature: 0.0,
          seed: seed,
          max_tokens: max_output_tokens,
          max_retries: 0,
          cache: false
        )

      %BudgetedLM{inner: inner, budget: budget, max_output_tokens: max_output_tokens}
    end
  end

  defp local_req_model("ollama:" <> id), do: %{provider: :ollama, id: id}
  defp local_req_model(model), do: model

  defp assert_ledger_open!(ledger) do
    case OpenRouterFreeGuard.ledger_snapshot(ledger)["halted"] do
      nil -> :ok
      reason -> raise "OpenRouter free ledger halted: #{reason}"
    end
  end

  defp last_provider_response(%{ledger: nil}), do: nil

  defp last_provider_response(%{ledger: ledger}) do
    ledger
    |> OpenRouterFreeGuard.ledger_snapshot()
    |> Map.get("responses", [])
    |> List.last()
  end

  defp failure_messages(%Imp.EvaluationCancelledError{} = error, _stacktrace) do
    Enum.map(error.errors || [], &safe_error/1)
  end

  defp failure_messages(error, stacktrace), do: [safe_exception(error, stacktrace)]

  defp failure_detail(%Imp.EvaluationCancelledError{} = error, _stacktrace) do
    %{
      "type" => "evaluation_cancelled",
      "message" => error.message,
      "max_errors" => error.max_errors,
      "adapter_or_program_errors" => Enum.map(error.errors || [], &structured_error/1),
      "partial_rows" => Enum.map(error.rows || [], &partial_failure_row/1)
    }
  end

  defp failure_detail(error, stacktrace) do
    %{"type" => "campaign_exception", "message" => safe_exception(error, stacktrace)}
  end

  defp partial_failure_row(row) do
    %{
      "index" => Map.get(row, :index),
      "score" => Map.get(row, :score),
      "error" => Map.get(row, :error) && safe_error(Map.get(row, :error)),
      "response" => response_accounting(Map.get(row, :prediction))
    }
  end

  defp structured_error(%{index: index, reason: %{reason: reason}}) do
    structured_error(index, reason)
  end

  defp structured_error(%{index: index, reason: reason}) do
    structured_error(index, reason)
  end

  defp structured_error(error) do
    structured_error(nil, error)
  end

  defp structured_error(index, {:error, reason}), do: structured_error(index, reason)

  defp structured_error(index, %Imp.AdapterParseError{} = error) do
    %{
      "index" => index,
      "category" => "adapter_decode",
      "reason_type" => inspect(error.__struct__),
      "message" => error.message,
      "reason" => safe_error(error.reason)
    }
  end

  defp structured_error(index, error) do
    %{
      "index" => index,
      "category" => "program_or_transport",
      "reason_type" => reason_type(error),
      "message" => nil,
      "reason" => safe_error(error)
    }
  end

  defp reason_type(%module{}), do: inspect(module)

  defp reason_type(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      _other -> "tuple"
    end
  end

  defp reason_type(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_type(_reason), do: "term"

  defp load_dataset!(path, _test_limit) do
    bytes = File.read!(path)
    data = Jason.decode!(bytes)
    train_rows = Map.fetch!(data, "train")
    dev_rows = Map.fetch!(data, "dev")
    test_rows = Map.fetch!(data, "test")
    chosen_test = Enum.map(@balanced_test_indices, &Enum.fetch!(test_rows, &1))

    all_tickets =
      Enum.flat_map([train_rows, dev_rows, test_rows], &Enum.map(&1, fn row -> row["ticket"] end))

    if length(all_tickets) != length(Enum.uniq(all_tickets)), do: raise("dataset tickets overlap")

    dataset = %{
      train: to_examples(train_rows),
      selection: to_examples(dev_rows),
      test: to_examples(chosen_test)
    }

    metadata = %{
      "path" => path,
      "sha256" => sha256(bytes),
      "train_rows" => length(train_rows),
      "selection_rows" => length(dev_rows),
      "untouched_test_rows_total" => length(test_rows),
      "untouched_test_rows_used" => length(chosen_test),
      "test_indices" => @balanced_test_indices,
      "train_sha256" => CampaignBudget.evidence_digest(train_rows),
      "selection_sha256" => CampaignBudget.evidence_digest(dev_rows),
      "test_sha256" => CampaignBudget.evidence_digest(chosen_test),
      "exact_ticket_overlap" => false
    }

    {dataset, metadata}
  end

  defp to_examples(rows) do
    Enum.map(rows, fn %{"ticket" => ticket, "team" => team} ->
      Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
    end)
  end

  defp validate_runtime!(runtime) when runtime in [:local, :openrouter_free], do: :ok

  defp validate_runtime!(runtime),
    do: raise(ArgumentError, "unsupported runtime #{inspect(runtime)}")

  defp validate_design!(seeds, arms, test_limit, runtime, campaign, max_output_tokens) do
    unless length(seeds) >= 3 and length(Enum.uniq(seeds)) == length(seeds),
      do: raise(ArgumentError, "campaign requires at least three distinct seeds")

    unless arms == @arms,
      do: raise(ArgumentError, "campaign arms must be baseline then labeled_few_shot")

    unless test_limit == @test_limit,
      do: raise(ArgumentError, "support-ticket campaign is pinned to eight balanced test rows")

    if runtime == :openrouter_free and {seeds, test_limit} != {@seeds, @test_limit},
      do:
        raise(ArgumentError, "free-provider campaign is pinned to seeds 17/23/31 and 8 test rows")

    case {runtime, campaign, max_output_tokens} do
      {:openrouter_free, "support-ticket-baseline-vs-labeled-few-shot", @v1_max_output_tokens} ->
        :ok

      {:openrouter_free, @v2_campaign_id, @v2_max_output_tokens} ->
        :ok

      {:local, "support-ticket-baseline-vs-labeled-few-shot", @v1_max_output_tokens} ->
        :ok

      _other ->
        raise ArgumentError,
              "campaign identity and output envelope do not match a frozen support-ticket protocol"
    end
  end

  defp validate_v2_manifest!(manifest) do
    expected_guard = %{
      "exact_model_suffix" => ":free",
      "max_price" => %{"prompt" => 0, "completion" => 0, "request" => 0, "image" => 0},
      "allow_fallbacks" => false,
      "require_parameters" => true,
      "data_collection" => "deny",
      "usage_include" => true,
      "fail_closed_on_nonzero_or_ambiguous_cost" => true,
      "single_transport_attempt_per_logical_request" => true
    }

    expected_execution = %{
      "logical_request_limit" => @expected_requests,
      "transport_attempt_limit" => @expected_requests,
      "max_concurrency" => 1,
      "json_retries" => 0,
      "transport_retries" => 0,
      "max_output_tokens" => @v2_max_output_tokens,
      "max_output_tokens_change_from_v1" => "64_to_256_only"
    }

    design = manifest["frozen_design"] || %{}
    execution = design["execution"] || %{}
    dataset = design["dataset"] || %{}
    predecessor = manifest["predecessor"] || %{}

    checks = [
      manifest["campaign_id"] == @v2_campaign_id,
      manifest["status"] == "preregistered_not_run",
      manifest["authorization"] == "not_launched",
      predecessor["artifact"] ==
        "benchmarks/results/support-ticket-lift-openrouter-free-20260725.json",
      predecessor["disposition"] == "frozen_stopped_incomplete",
      predecessor["sha256"] == file_sha256(predecessor["artifact"]),
      dataset["path"] == "priv/tutorial/support_tickets.json",
      dataset["sha256"] == file_sha256(dataset["path"]),
      dataset["untouched_test_indices"] == @balanced_test_indices,
      dataset["test_visible_to_optimization_or_selection"] == false,
      design["seeds"] == @seeds,
      Enum.map(design["arms"] || [], & &1["id"]) == Enum.map(@arms, &Atom.to_string/1),
      get_in(design, ["arms", Access.at(1), "options"]) == %{
        "k" => 8,
        "sample" => true,
        "seed" => "campaign_seed"
      },
      design["metric"] == "Imp.exact_match(:team)",
      design["signature"] == "ticket -> team: enum[atlas,harbor,beacon,quill]",
      get_in(design, ["model", "requested"]) == OpenRouterFreeGuard.model(),
      Map.take(execution, Map.keys(expected_execution)) == expected_execution,
      design["provider_guard"] == expected_guard,
      manifest["required_failure_capture"] != [],
      manifest["stop_rules"] != [],
      get_in(manifest, ["decision_rules", "within_task_go"]) ==
        "Mean held-out lift is at least 0.03, the exact paired-bootstrap 95% lower bound is above zero, and at least two of three seeds improve."
    ]

    unless Enum.all?(checks), do: raise(ArgumentError, "v2 campaign manifest drifted")
    :ok
  end

  defp file_sha256(nil), do: nil
  defp file_sha256(path), do: path |> File.read!() |> sha256()

  defp model_name(:openrouter_free, _opts), do: OpenRouterFreeGuard.model()
  defp model_name(:local, opts), do: Keyword.get(opts, :model, "ollama:llama3.2:3b")

  defp elapsed_seconds(started),
    do: (System.monotonic_time(:millisecond) - started) / 1000.0

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp map_value(nil, _key), do: nil
  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp map_value(_other, _key), do: nil

  defp safe_exception(%_{} = error, stacktrace),
    do: Exception.format(:error, error, stacktrace) |> safe_error()

  defp safe_exception(error, _stacktrace), do: safe_error(error)

  defp safe_error(error),
    do: error |> inspect(limit: 20, printable_limit: 500) |> Imp.Redaction.redact()
end
