defmodule DSEx.BenchmarkTruth.OptimizeAnything.Campaign do
  @moduledoc false

  alias DSEx.BenchmarkTruth.ArtifactFile

  alias DSEx.BenchmarkTruth.OptimizeAnything.{
    AgentConfig,
    Artifact,
    CodeArtifact,
    SchedulingHeuristic
  }

  alias DSEx.Optimize.Anything, as: OptimizeAnything
  alias DSEx.Optimize.Anything.{Config, Result}

  @gepa_commit "b4dbb55b7601dac448cdb836d5a401ca7d9eb920"
  @evaluators [CodeArtifact, AgentConfig, SchedulingHeuristic]
  @default_seeds [0, 1, 2]

  @doc "Runs a complete campaign and writes its versioned evidence artifact."
  def run(opts) when is_list(opts) do
    lm = Keyword.fetch!(opts, :lm)
    model = Keyword.fetch!(opts, :model)
    provider = Keyword.fetch!(opts, :provider)
    out_dir = Keyword.get(opts, :out_dir, "benchmarks/results")
    seeds = validate_seeds!(Keyword.get(opts, :seeds, @default_seeds))
    max_proposals = Keyword.get(opts, :max_proposals, 3)
    run_id = Keyword.get(opts, :run_id, run_id())
    git_sha = git_sha()

    unless is_integer(max_proposals) and max_proposals > 0 do
      raise ArgumentError, ":max_proposals must be a positive integer"
    end

    File.mkdir_p!(out_dir)

    context = %{
      lm: lm,
      provider: provider,
      model: model,
      seeds: seeds,
      max_proposals: max_proposals,
      out_dir: out_dir,
      run_id: run_id,
      git_sha: git_sha
    }

    rows =
      Enum.map(@evaluators, fn evaluator ->
        run_evaluator(evaluator, context)
      end)

    artifact =
      Artifact.build(rows,
        mode: :full,
        git_sha: git_sha,
        source: %{
          "mode" => "live_campaign",
          "run_id" => run_id,
          "provider" => provider,
          "model" => model,
          "seeds" => seeds,
          "max_proposals" => max_proposals
        }
      )

    path = Path.join(out_dir, "optimize-anything-replication-#{timestamp_slug()}.json")
    path = ArtifactFile.write_json!(path, artifact)

    unless Artifact.full_artifact?(artifact) do
      raise "Optimize Anything live campaign did not produce full effectiveness evidence; inspect #{path}"
    end

    %{artifact: artifact, out_path: path}
  end

  def run(opts),
    do: raise(ArgumentError, "campaign options must be a keyword list, got: #{inspect(opts)}")

  @doc false
  def handle_usage(_event, measurements, _metadata, agent) do
    Agent.update(agent, &sum_usage(&1, usage_from_measurements(measurements)))
  end

  defp run_evaluator(evaluator, context) do
    %{
      lm: lm,
      provider: provider,
      model: model,
      seeds: seeds,
      max_proposals: max_proposals,
      out_dir: out_dir,
      run_id: run_id,
      git_sha: git_sha
    } = context

    baseline_score = score(evaluator, evaluator.baseline(), evaluator.valset())
    comparator_score = score(evaluator, evaluator.comparator(), evaluator.valset())

    runs =
      Enum.map(seeds, fn seed ->
        run_seed(evaluator, lm, seed, max_proposals, out_dir, run_id, baseline_score, git_sha)
      end)

    lifts = Enum.map(runs, &(&1.optimized_score - baseline_score))

    unless Enum.count(lifts, &(&1 > 0)) > div(length(lifts), 2) and
             Enum.sum(lifts) / length(lifts) > 0 do
      raise "#{evaluator.id()} failed the multi-seed held-out effectiveness policy"
    end

    representative = Enum.max_by(runs, & &1.optimized_score)
    usage = Enum.reduce(runs, empty_usage(), &sum_usage(&2, &1.usage))
    wall_time_ms = runs |> Enum.map(& &1.wall_time_ms) |> Enum.sum()
    metric_calls = runs |> Enum.map(& &1.metric_calls) |> Enum.sum()
    absolute_lift = representative.optimized_score - baseline_score

    %{
      "artifact_class" => evaluator.artifact_class(),
      "evaluator_id" => evaluator.id(),
      "baseline" => %{"artifact" => evaluator.baseline(), "score" => baseline_score},
      "optimized" => %{
        "artifact" => representative.artifact,
        "score" => representative.optimized_score
      },
      "comparator" => %{
        "artifact" => evaluator.comparator(),
        "score" => comparator_score
      },
      "absolute_lift" => absolute_lift,
      "relative_lift" => absolute_lift / abs(baseline_score),
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
      "train_digest" => digest(evaluator.trainset()),
      "val_digest" => digest(evaluator.valset()),
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
          "mix dsex.benchmark.optimize_anything --live --provider #{provider} --model #{model} --seeds #{Enum.join(seeds, ",")}",
        "evaluator_version" => evaluator.id(),
        "dataset_source" => "embedded DSEx benchmark truth corpus with executable evaluators",
        "environment" => "Elixir #{System.version()} / OTP #{System.otp_release()}",
        "source_commits" => %{"dsex" => git_sha, "gepa" => @gepa_commit},
        "runs" => Enum.map(runs, &reproducibility_run/1)
      }
    }
  end

  defp run_seed(evaluator, lm, seed, max_proposals, out_dir, run_id, baseline_score, git_sha) do
    run_dir =
      Path.join([
        out_dir,
        "optimize-anything-runs",
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

    {elapsed_us, result, usage} =
      measure_usage(fn ->
        :timer.tc(fn ->
          OptimizeAnything.optimize(
            evaluator.baseline(),
            &evaluator.evaluate/2,
            config: config,
            dataset: evaluator.trainset(),
            valset: evaluator.valset(),
            objective:
              evaluator.metadata()["objective"] || evaluator.metadata()[:objective] ||
                "Maximize held-out evaluator score while preserving the candidate contract.",
            background: Jason.encode!(evaluator.metadata(), pretty: true)
          )
        end)
      end)

    artifact = Result.best_candidate(result)
    optimized_score = score(evaluator, artifact, evaluator.valset())
    checkpoint = persist_final_checkpoint(run_dir, result, git_sha)

    %{
      seed: seed,
      artifact: artifact,
      artifact_digest: digest(artifact),
      baseline_score: baseline_score,
      optimized_score: optimized_score,
      metric_calls: result.total_metric_calls,
      wall_time_ms: max(div(elapsed_us, 1_000), 1),
      usage: usage,
      run_id: "#{run_id}/#{evaluator.artifact_class()}/#{seed}",
      checkpoint: checkpoint
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

  defp measure_usage(fun) do
    handler_id = {__MODULE__, :usage, make_ref()}
    {:ok, agent} = Agent.start_link(fn -> empty_usage() end)

    :ok =
      :telemetry.attach(handler_id, [:req_llm, :token_usage], &__MODULE__.handle_usage/4, agent)

    try do
      {elapsed_us, result} = fun.()
      {elapsed_us, result, Agent.get(agent, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(agent)
    end
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
      "baseline_score" => run.baseline_score,
      "optimized_score" => run.optimized_score,
      "lift" => run.optimized_score - run.baseline_score,
      "artifact_digest" => run.artifact_digest,
      "metric_calls" => run.metric_calls,
      "wall_time_ms" => run.wall_time_ms,
      "input_tokens" => run.usage.input_tokens,
      "output_tokens" => run.usage.output_tokens,
      "cost_usd" => run.usage.cost_usd,
      "run_id" => run.run_id,
      "checkpoint" => run.checkpoint
    }
  end

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

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--verify", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp run_id,
    do: "oa-" <> timestamp_slug() <> "-" <> Integer.to_string(System.unique_integer([:positive]))

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
