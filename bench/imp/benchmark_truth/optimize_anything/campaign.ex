defmodule Imp.BenchmarkTruth.OptimizeAnything.Campaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, BudgetedLM, CampaignBudget, RunContext}

  alias Imp.BenchmarkTruth.OptimizeAnything.{
    AgentConfig,
    Artifact,
    CodeArtifact,
    PricingPolicy,
    SchedulingHeuristic
  }

  alias Imp.Optimize.Anything, as: OptimizeAnything
  alias Imp.Optimize.Anything.{Config, Result}

  @evaluators [CodeArtifact, AgentConfig, SchedulingHeuristic]
  @default_seeds [0, 1, 2]

  @doc "Runs a complete campaign and writes its versioned evidence artifact."
  def run(opts) when is_list(opts) do
    lm = Keyword.fetch!(opts, :lm)
    model = Keyword.fetch!(opts, :model)
    provider = Keyword.fetch!(opts, :provider)

    out_dir =
      Keyword.get(opts, :out_dir, Imp.BenchmarkTruth.Paths.runs("optimize-anything"))

    checkpoint_root =
      Keyword.get(
        opts,
        :checkpoint_dir,
        Imp.BenchmarkTruth.Paths.checkpoints("optimize-anything")
      )

    seeds = validate_seeds!(Keyword.get(opts, :seeds, @default_seeds))
    max_proposals = Keyword.get(opts, :max_proposals, 3)
    run_id = Keyword.get(opts, :run_id, run_id())
    gepa_commit = current_gepa_commit!()
    budget_config = validate_budget_config!(opts)

    unless is_integer(max_proposals) and max_proposals > 0 do
      raise ArgumentError, ":max_proposals must be a positive integer"
    end

    validate_request_opportunity!(budget_config.limits, seeds, max_proposals)

    source = %{
      "mode" => "live_campaign",
      "run_id" => run_id,
      "provider" => provider,
      "model" => model,
      "seeds" => seeds,
      "max_proposals" => max_proposals,
      "budget" => budget_config.source
    }

    run_context =
      RunContext.capture_git!(
        source_commits: %{"gepa" => "gepa-ai/gepa@#{gepa_commit}"},
        inputs: source
      )

    git_sha = run_context.code_revision
    run_root = campaign_run_root!(checkpoint_root, run_id)
    budget_checkpoint = Path.join(run_root, "campaign-budget.json")

    if File.exists?(run_root) or File.exists?(budget_checkpoint) do
      raise ArgumentError,
            "Optimize Anything run id #{inspect(run_id)} already has checkpoint state; use a new run id"
    end

    File.mkdir_p!(out_dir)

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: budget_config.limits,
        pricing: budget_config.pricing,
        default_max_output_tokens: budget_config.max_output_tokens_per_request,
        on_change: &persist_budget_checkpoint(budget_checkpoint, &1)
      )

    telemetry_owner = self()
    budget_handler = CampaignBudget.attach_req_llm(budget, owner: telemetry_owner)
    audit_handler = {__MODULE__, :usage_audit, make_ref()}
    {:ok, usage_audit} = Agent.start_link(fn -> empty_usage_audit() end)

    :ok =
      :telemetry.attach(
        audit_handler,
        [:req_llm, :token_usage],
        &__MODULE__.handle_usage/4,
        {usage_audit, telemetry_owner}
      )

    context = %{
      lm: %BudgetedLM{
        inner: lm,
        budget: budget,
        max_output_tokens: budget_config.max_output_tokens_per_request
      },
      budget: budget,
      usage_audit: usage_audit,
      provider: provider,
      model: model,
      seeds: seeds,
      max_proposals: max_proposals,
      checkpoint_root: checkpoint_root,
      run_id: run_id,
      git_sha: git_sha,
      gepa_commit: gepa_commit,
      budget_checkpoint: budget_checkpoint,
      budget_config: budget_config
    }

    try do
      rows =
        Enum.map(@evaluators, fn evaluator ->
          run_evaluator(evaluator, context)
        end)

      budget_snapshot = CampaignBudget.snapshot(budget)
      validate_final_budget!(budget_snapshot, Agent.get(usage_audit, & &1))
      persist_budget_checkpoint(budget_checkpoint, budget_snapshot)
      budget_checkpoint_evidence = read_budget_checkpoint!(budget_checkpoint, budget_snapshot)

      rows =
        Enum.map(rows, fn row ->
          row
          |> Map.put("campaign_budget", budget_snapshot)
          |> put_in(["provenance", "budget_checkpoint"], budget_checkpoint)
          |> put_in(["reproducibility", "budget"], budget_snapshot)
        end)

      artifact =
        Artifact.build(rows,
          mode: :full,
          git_sha: git_sha,
          source: source
        )
        |> Map.put("budget_checkpoint", budget_checkpoint_evidence)

      path = Path.join(out_dir, "optimize-anything-replication-#{timestamp_slug()}.json")

      %{artifact: artifact, path: path} =
        ArtifactFile.write_run_json!(path, artifact, run_context)

      unless Artifact.full_artifact?(artifact) do
        raise "Optimize Anything live campaign did not produce full effectiveness evidence; inspect #{path}"
      end

      %{artifact: artifact, out_path: path}
    after
      if Process.alive?(budget) do
        persist_budget_checkpoint(budget_checkpoint, CampaignBudget.snapshot(budget))
      end

      :telemetry.detach(audit_handler)
      :telemetry.detach(budget_handler)
      Agent.stop(usage_audit)
      GenServer.stop(budget)
    end
  end

  def run(opts),
    do: raise(ArgumentError, "campaign options must be a keyword list, got: #{inspect(opts)}")

  @doc false
  def handle_usage(_event, _measurements, _metadata, {_agent, owner})
      when owner != self(),
      do: :ok

  def handle_usage(event, measurements, metadata, {agent, _owner}),
    do: handle_usage(event, measurements, metadata, agent)

  def handle_usage(_event, measurements, _metadata, agent) do
    Agent.update(agent, fn audit ->
      usage = usage_from_measurements(measurements)

      %{
        audit
        | events: audit.events + 1,
          invalid_cost_events:
            audit.invalid_cost_events + if(positive_finite?(usage.cost_usd), do: 0, else: 1)
      }
    end)
  end

  defp run_evaluator(evaluator, context) do
    %{
      lm: lm,
      budget: budget,
      usage_audit: usage_audit,
      provider: provider,
      model: model,
      seeds: seeds,
      max_proposals: max_proposals,
      checkpoint_root: checkpoint_root,
      run_id: run_id,
      git_sha: git_sha,
      gepa_commit: gepa_commit,
      budget_checkpoint: budget_checkpoint,
      budget_config: budget_config
    } = context

    baseline_selection_score = score(evaluator, evaluator.baseline(), evaluator.valset())
    comparator_selection_score = score(evaluator, evaluator.comparator(), evaluator.valset())
    baseline_test_score = score(evaluator, evaluator.baseline(), evaluator.testset())
    comparator_test_score = score(evaluator, evaluator.comparator(), evaluator.testset())

    runs =
      Enum.map(seeds, fn seed ->
        run_seed(
          evaluator,
          lm,
          budget,
          usage_audit,
          seed,
          max_proposals,
          checkpoint_root,
          run_id,
          baseline_selection_score,
          baseline_test_score,
          git_sha,
          budget_checkpoint
        )
      end)

    test_lifts = Enum.map(runs, & &1.test_lift)

    unless Enum.count(test_lifts, &(&1 > 0)) > div(length(test_lifts), 2) and
             Enum.sum(test_lifts) / length(test_lifts) > 0 do
      raise "#{evaluator.id()} failed the multi-seed held-out effectiveness policy"
    end

    representative = select_representative(runs)
    usage = Enum.reduce(runs, empty_usage(), &sum_usage(&2, &1.usage))
    wall_time_ms = runs |> Enum.map(& &1.wall_time_ms) |> Enum.sum()
    metric_calls = runs |> Enum.map(& &1.metric_calls) |> Enum.sum()
    absolute_lift = representative.test_score - baseline_test_score

    %{
      "artifact_class" => evaluator.artifact_class(),
      "evaluator_id" => evaluator.id(),
      "baseline" => %{"artifact" => evaluator.baseline(), "score" => baseline_test_score},
      "optimized" => %{
        "artifact" => representative.artifact,
        "score" => representative.test_score
      },
      "comparator" => %{
        "artifact" => evaluator.comparator(),
        "score" => comparator_test_score
      },
      "selection" => %{
        "baseline_score" => baseline_selection_score,
        "optimized_score" => representative.selection_score,
        "comparator_score" => comparator_selection_score
      },
      "absolute_lift" => absolute_lift,
      "relative_lift" => absolute_lift / abs(baseline_test_score),
      "metric_calls" => metric_calls,
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "provider" => provider,
      "model" => model,
      "cost_usd" => usage.cost_usd,
      "wall_time_ms" => wall_time_ms,
      "seed" => representative.seed,
      "train_count" => length(evaluator.trainset()),
      "val_count" => length(evaluator.valset()),
      "test_count" => length(evaluator.testset()),
      "train_digest" => digest(evaluator.trainset()),
      "val_digest" => digest(evaluator.valset()),
      "test_digest" => digest(evaluator.testset()),
      "provenance" => %{
        "run_id" => run_id,
        "checkpoint" => representative.checkpoint,
        "git_sha" => git_sha
      },
      "status" => "live",
      "effectiveness_authorized" => true,
      "evaluator_metadata" => evaluator.metadata(),
      "reproducibility" => %{
        "command" =>
          reproducibility_command(provider, model, seeds, max_proposals, budget_config),
        "evaluator_version" => evaluator.id(),
        "dataset_source" =>
          "embedded Imp benchmark truth corpus with disjoint train, selection, and untouched test splits",
        "environment" => "Elixir #{System.version()} / OTP #{System.otp_release()}",
        "source_commits" => %{"imp" => git_sha, "gepa" => gepa_commit},
        "runs" => Enum.map(runs, &reproducibility_run/1)
      }
    }
  end

  @doc false
  def select_representative(runs) when is_list(runs) and runs != [] do
    Enum.max_by(runs, &{&1.selection_score, -&1.seed})
  end

  defp current_gepa_commit! do
    "benchmarks/authorities.json"
    |> Imp.EvidenceAuthorities.load!()
    |> get_in(["pinned_sources", "gepa_standalone", "commit"])
    |> case do
      commit when is_binary(commit) and byte_size(commit) == 40 -> commit
      value -> raise "canonical GEPA authority has an invalid commit: #{inspect(value)}"
    end
  end

  defp run_seed(
         evaluator,
         lm,
         budget,
         usage_audit,
         seed,
         max_proposals,
         checkpoint_root,
         run_id,
         baseline_selection_score,
         baseline_test_score,
         git_sha,
         budget_checkpoint
       ) do
    run_dir =
      Path.join([
        checkpoint_root,
        run_id,
        evaluator.artifact_class(),
        Integer.to_string(seed)
      ])

    config =
      Config.new(
        engine: [
          run_dir: run_dir,
          seed: seed,
          max_candidate_proposals: max_proposals,
          max_workers: 1,
          parallel: false,
          cache_evaluation: true,
          cache_evaluation_storage: :disk,
          track_best_outputs: true
        ],
        reflection: [
          reflection_lm: lm,
          reflection_minibatch_size: length(evaluator.trainset()),
          skip_perfect_score: true,
          perfect_score: 1.0
        ]
      )

    before_budget = CampaignBudget.snapshot(budget)
    before_events = Agent.get(usage_audit, & &1.events)

    {elapsed_us, result} =
      :timer.tc(fn ->
        OptimizeAnything.run(
          evaluator.baseline(),
          &evaluator.evaluate/2,
          config: config,
          dataset: evaluator.trainset(),
          valset: evaluator.valset(),
          objective:
            evaluator.metadata()["objective"] || evaluator.metadata()[:objective] ||
              "Maximize development evaluator score while preserving the candidate contract.",
          background: Jason.encode!(evaluator.metadata(), pretty: true)
        )
      end)

    after_budget = CampaignBudget.snapshot(budget)
    after_audit = Agent.get(usage_audit, & &1)
    usage = budget_usage_delta(before_budget, after_budget)
    request_count = after_budget["requests"] - before_budget["requests"]
    event_count = after_audit.events - before_events

    validate_seed_usage!(usage, request_count, event_count, after_audit)

    artifact = Result.best_candidate(result)
    selection_score = score(evaluator, artifact, evaluator.valset())
    test_score = score(evaluator, artifact, evaluator.testset())
    checkpoint = persist_final_checkpoint(run_dir, result, git_sha)

    %{
      seed: seed,
      artifact: artifact,
      artifact_digest: digest(artifact),
      baseline_selection_score: baseline_selection_score,
      selection_score: selection_score,
      selection_lift: selection_score - baseline_selection_score,
      baseline_test_score: baseline_test_score,
      test_score: test_score,
      test_lift: test_score - baseline_test_score,
      metric_calls: result.total_metric_calls,
      wall_time_ms: max(div(elapsed_us, 1_000), 1),
      usage: usage,
      request_count: request_count,
      run_id: "#{run_id}/#{evaluator.artifact_class()}/#{seed}",
      checkpoint: checkpoint,
      budget_checkpoint: budget_checkpoint
    }
  end

  defp score(evaluator, artifact, examples) do
    examples
    |> Enum.map(fn example ->
      case evaluator.evaluate(artifact, example) do
        {value, diagnostics} when is_number(value) and is_map(diagnostics) -> value
        invalid -> raise "#{evaluator.id()} returned invalid evaluation: #{inspect(invalid)}"
      end
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  defp persist_final_checkpoint(run_dir, result, git_sha) do
    path = Path.join(run_dir, "final-checkpoint.json")

    ArtifactFile.write_json!(path, %{
      "git_sha" => git_sha,
      "result" => Result.to_map(result)
    })
  end

  defp usage_from_measurements(measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    %{
      cost_usd: usage_number(measurements, [:total_cost, :cost]),
      input_tokens: trunc(usage_number(tokens, [:input_tokens, :input])),
      output_tokens: trunc(usage_number(tokens, [:output_tokens, :output]))
    }
  end

  defp usage_number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
      if is_number(value), do: value
    end)
  end

  defp sum_usage(left, right) do
    %{
      cost_usd: left.cost_usd + right.cost_usd,
      input_tokens: left.input_tokens + right.input_tokens,
      output_tokens: left.output_tokens + right.output_tokens
    }
  end

  defp empty_usage, do: %{cost_usd: 0.0, input_tokens: 0, output_tokens: 0}

  defp reproducibility_run(run) do
    %{
      "seed" => run.seed,
      "baseline_selection_score" => run.baseline_selection_score,
      "selection_score" => run.selection_score,
      "selection_lift" => run.selection_lift,
      "baseline_test_score" => run.baseline_test_score,
      "test_score" => run.test_score,
      "test_lift" => run.test_lift,
      "artifact_digest" => run.artifact_digest,
      "metric_calls" => run.metric_calls,
      "wall_time_ms" => run.wall_time_ms,
      "input_tokens" => run.usage.input_tokens,
      "output_tokens" => run.usage.output_tokens,
      "cost_usd" => run.usage.cost_usd,
      "request_count" => run.request_count,
      "run_id" => run.run_id,
      "checkpoint" => run.checkpoint,
      "budget_checkpoint" => run.budget_checkpoint
    }
  end

  defp validate_budget_config!(opts) do
    limits = Keyword.fetch!(opts, :limits)
    pricing = Keyword.fetch!(opts, :pricing)
    pricing_source_url = Keyword.fetch!(opts, :pricing_source_url)
    pricing_profile = Keyword.get(opts, :pricing_profile, "custom")
    max_output_tokens_per_request = Keyword.fetch!(opts, :max_output_tokens_per_request)

    required_limits = [:requests, :input_tokens, :output_tokens, :usd]

    unless Enum.all?(required_limits, fn key ->
             value = Map.get(limits, key, Map.get(limits, Atom.to_string(key)))
             is_number(value) and value > 0 and (key == :usd or is_integer(value))
           end) do
      raise ArgumentError,
            ":limits must set positive finite requests, input_tokens, output_tokens, and usd ceilings"
    end

    PricingPolicy.resolve!(
      Keyword.fetch!(opts, :provider),
      Keyword.fetch!(opts, :model),
      pricing_profile,
      pricing,
      pricing_source_url
    )

    unless is_integer(max_output_tokens_per_request) and max_output_tokens_per_request > 0 and
             max_output_tokens_per_request <=
               Map.get(limits, :output_tokens, Map.get(limits, "output_tokens")) do
      raise ArgumentError,
            ":max_output_tokens_per_request must be positive and no greater than the output-token ceiling"
    end

    %{
      limits: limits,
      pricing: Map.put(pricing, "source_url", pricing_source_url),
      pricing_profile: pricing_profile,
      max_output_tokens_per_request: max_output_tokens_per_request,
      source: %{
        "limits" => stringify_keys(limits),
        "pricing" => Map.put(pricing, "source_url", pricing_source_url),
        "pricing_profile" => pricing_profile,
        "max_output_tokens_per_request" => max_output_tokens_per_request,
        "request_policy" => %{"cache" => false, "max_retries" => 0}
      }
    }
  end

  defp validate_request_opportunity!(limits, seeds, max_proposals) do
    required = length(@evaluators) * length(seeds) * max_proposals
    configured = Map.get(limits, :requests, Map.get(limits, "requests"))

    unless configured >= required do
      raise ArgumentError,
            ":limits request ceiling #{configured} cannot execute the declared campaign opportunity; " <>
              "#{length(@evaluators)} artifact classes * #{length(seeds)} seeds * " <>
              "#{max_proposals} proposals requires at least #{required} requests"
    end
  end

  defp persist_budget_checkpoint(path, snapshot) do
    payload = %{
      "schema_version" => 1,
      "kind" => "optimize_anything_campaign_budget",
      "budget" => snapshot
    }

    envelope = %{
      "payload_sha256" => CampaignBudget.evidence_digest(payload),
      "payload" => payload
    }

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(envelope, pretty: true) <> "\n", [:sync, :exclusive])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    path
  end

  defp read_budget_checkpoint!(path, expected_snapshot) do
    envelope = path |> File.read!() |> Jason.decode!()
    payload = envelope["payload"]

    unless envelope["payload_sha256"] == CampaignBudget.evidence_digest(payload) and
             payload == %{
               "schema_version" => 1,
               "kind" => "optimize_anything_campaign_budget",
               "budget" => expected_snapshot
             } do
      raise "Optimize Anything budget checkpoint failed its final integrity check"
    end

    envelope
  end

  defp campaign_run_root!(checkpoint_root, run_id) do
    unless is_binary(run_id) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, run_id) do
      raise ArgumentError, ":run_id must be a safe nonempty path fragment"
    end

    root = Path.expand(checkpoint_root)
    run_root = Path.expand(run_id, root)

    unless String.starts_with?(run_root, root <> "/") do
      raise ArgumentError, ":run_id escapes the checkpoint root"
    end

    run_root
  end

  defp budget_usage_delta(before, after_snapshot) do
    before_usage = before["usage"]
    after_usage = after_snapshot["usage"]

    %{
      cost_usd: after_usage["usd"] - before_usage["usd"],
      input_tokens: after_usage["input_tokens"] - before_usage["input_tokens"],
      output_tokens: after_usage["output_tokens"] - before_usage["output_tokens"]
    }
  end

  defp validate_seed_usage!(usage, request_count, event_count, audit) do
    cond do
      request_count <= 0 ->
        raise "Optimize Anything live seed made no provider requests"

      event_count != request_count ->
        raise "Optimize Anything live seed requires exactly one usage event per provider request"

      audit.invalid_cost_events > 0 ->
        raise "Optimize Anything live usage event has missing, zero, or non-finite cost"

      not positive_finite?(usage.cost_usd) ->
        raise "Optimize Anything live seed has missing, zero, or non-finite cost"

      usage.input_tokens <= 0 or usage.output_tokens <= 0 ->
        raise "Optimize Anything live seed has missing or zero token accounting"

      true ->
        :ok
    end
  end

  defp validate_final_budget!(snapshot, audit) do
    cond do
      snapshot["active_reservations"] != 0 ->
        raise "Optimize Anything campaign ended with active budget reservations"

      snapshot["exhausted"] != nil ->
        raise "Optimize Anything campaign exceeded its declared #{snapshot["exhausted"]} ceiling"

      not usage_within_limits?(snapshot) ->
        raise "Optimize Anything campaign observed usage exceeds its declared ceilings"

      snapshot["requests"] != audit.events ->
        raise "Optimize Anything campaign request and usage-event counts differ"

      audit.invalid_cost_events > 0 or not positive_finite?(snapshot["usage"]["usd"]) ->
        raise "Optimize Anything campaign has incomplete provider cost accounting"

      true ->
        :ok
    end
  end

  defp usage_within_limits?(snapshot) do
    limits = snapshot["limits"]
    usage = snapshot["usage"]

    snapshot["requests"] <= limits["requests"] and
      usage["input_tokens"] <= limits["input_tokens"] and
      usage["output_tokens"] <= limits["output_tokens"] and usage["usd"] <= limits["usd"]
  end

  defp reproducibility_command(provider, model, seeds, max_proposals, budget_config) do
    limits = budget_config.limits
    pricing_args = reproducibility_pricing_args(budget_config)

    "mix imp.benchmark.optimize_anything --live --provider #{provider} --model #{model}" <>
      " --seeds #{Enum.join(seeds, ",")} --max-proposals #{max_proposals}" <>
      pricing_args <>
      " --max-cost-usd #{limit_value(limits, :usd)}" <>
      " --max-requests #{limit_value(limits, :requests)}" <>
      " --max-input-tokens #{limit_value(limits, :input_tokens)}" <>
      " --max-output-tokens #{limit_value(limits, :output_tokens)}" <>
      " --max-output-tokens-per-request #{budget_config.max_output_tokens_per_request}"
  end

  defp reproducibility_pricing_args(%{pricing_profile: "custom", pricing: pricing}) do
    " --input-price-per-million #{pricing["input_per_million"]}" <>
      " --output-price-per-million #{pricing["output_per_million"]}" <>
      " --pricing-source-url #{shell_arg(pricing["source_url"])}"
  end

  defp reproducibility_pricing_args(%{pricing_profile: profile}),
    do: " --pricing-profile #{shell_arg(profile)}"

  defp shell_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp limit_value(limits, key), do: Map.get(limits, key, Map.get(limits, Atom.to_string(key)))

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp positive_finite?(value) when is_number(value),
    do: value > 0 and match?({:ok, _encoded}, Jason.encode(value))

  defp positive_finite?(_value), do: false

  defp empty_usage_audit, do: %{events: 0, invalid_cost_events: 0}

  defp validate_seeds!(seeds) when is_list(seeds) and length(seeds) >= 3 do
    if Enum.all?(seeds, &is_integer/1) and Enum.uniq(seeds) == seeds,
      do: seeds,
      else: raise(ArgumentError, ":seeds must contain distinct integers")
  end

  defp validate_seeds!(_seeds),
    do: raise(ArgumentError, ":seeds must contain at least three distinct integers")

  defp digest(value) do
    encoded = :erlang.term_to_binary(value, [:deterministic])
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp run_id,
    do: "oa-" <> timestamp_slug() <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
