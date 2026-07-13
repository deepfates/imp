defmodule DSEx.BenchmarkTruth.InstructionOptimizerCampaign do
  @moduledoc false

  alias DSEx.BenchmarkTruth.{BudgetedLM, CampaignBudget, GepaMetrics}
  alias DSEx.Optimizer.{BootstrapFewShot, MIPROv2, Report, SIMBA, TrajectoryRunner}

  @schema_version 1
  @default_arms [:baseline, :bootstrap_few_shot, :mipro_v2, :simba]

  def run(opts) do
    context = build_context!(opts)
    checkpoint = load_checkpoint!(context.checkpoint_path, context.identity)
    runner = Keyword.get(opts, :arm_runner, &run_dsex_arm/3)

    checkpoint =
      Enum.reduce(context.arms, checkpoint, fn arm, checkpoint ->
        key = Atom.to_string(arm)

        if Map.has_key?(checkpoint["completed"], key) do
          checkpoint
        else
          progress = checkpoint["in_progress"][key] || %{}

          persist = fn progress ->
            updated = put_in(checkpoint, ["in_progress", key], progress)
            write_checkpoint!(context.checkpoint_path, updated)
          end

          result = runner.(arm, context, {progress, persist})

          updated =
            checkpoint
            |> put_in(["completed", key], result)
            |> update_in(["in_progress"], &Map.delete(&1, key))

          write_checkpoint!(context.checkpoint_path, updated)
          updated
        end
      end)

    artifact = artifact(context, checkpoint)
    path = Path.join(context.out_dir, "instruction-optimizer-campaign-#{timestamp_slug()}.json")
    write_json_atomic!(path, artifact)
    %{artifact: artifact, path: path, checkpoint_path: context.checkpoint_path}
  end

  defp build_context!(opts) do
    dataset_root = opts |> Keyword.fetch!(:dataset_root) |> Path.expand()
    family = Keyword.get(opts, :family, "AIMEBench")

    unless family == "AIMEBench" do
      raise ArgumentError, "instruction optimizer preflight currently supports AIMEBench only"
    end

    spec = load_spec!(dataset_root, family)
    paths = split_paths(dataset_root, family)
    verify_splits!(spec, paths)
    input_keys = spec["input_keys"]
    arms = validate_arms!(Keyword.get(opts, :arms, @default_arms))
    seed = Keyword.get(opts, :seed, 17)
    model = Keyword.fetch!(opts, :model)
    git_sha = Keyword.get_lazy(opts, :git_sha, &git_sha/0)

    source_commits =
      Map.put(Keyword.fetch!(opts, :source_commits), "dsex", "deepfates/dsex@#{git_sha}")

    out_dir = Keyword.get(opts, :out_dir, "benchmarks/results") |> Path.expand()

    checkpoint_dir =
      Keyword.get(opts, :checkpoint_dir, Path.join(out_dir, "optimizer-checkpoints"))

    campaign_id = Keyword.fetch!(opts, :campaign_id)
    File.mkdir_p!(out_dir)
    File.mkdir_p!(checkpoint_dir)

    context = %{
      campaign_id: campaign_id,
      dataset_root: dataset_root,
      family: family,
      spec: spec,
      paths: paths,
      trainset: DSEx.Datasets.jsonl(paths.train, input_keys),
      devset: DSEx.Datasets.jsonl(paths.dev, input_keys),
      testset: DSEx.Datasets.jsonl(paths.test, input_keys),
      seed: seed,
      model: model,
      lm: Keyword.fetch!(opts, :lm),
      arms: arms,
      arm_configs: Keyword.fetch!(opts, :arm_configs),
      budget: Keyword.fetch!(opts, :budget),
      pricing: Keyword.fetch!(opts, :pricing),
      max_output_tokens: Keyword.fetch!(opts, :max_output_tokens),
      source_commits: source_commits,
      git_sha: git_sha,
      out_dir: out_dir,
      checkpoint_path: checkpoint_path(checkpoint_dir, campaign_id, family, seed)
    }

    Map.put(context, :identity, identity(context))
  end

  defp identity(context) do
    %{
      "schema_version" => @schema_version,
      "campaign_id" => context.campaign_id,
      "family" => context.family,
      "seed" => context.seed,
      "model" => context.model,
      "arms" => Enum.map(context.arms, &Atom.to_string/1),
      "arm_configs" => Report.json_safe(context.arm_configs),
      "budget" => Report.json_safe(context.budget),
      "budget_scope" => "per_arm",
      "pricing" => context.pricing,
      "max_output_tokens" => context.max_output_tokens,
      "source_commits" => context.source_commits,
      "git_sha" => context.git_sha,
      "split_checksums" => split_checksums(context.paths)
    }
  end

  defp run_dsex_arm(arm, context, {progress, persist}) do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: context.budget,
        pricing: context.pricing,
        default_max_output_tokens: context.max_output_tokens,
        initial: progress["budget"] || %{}
      )

    telemetry_id = CampaignBudget.attach_req_llm(budget)
    budgeted_lm = %BudgetedLM{inner: context.lm, budget: budget}
    metric = GepaMetrics.metric(context.spec)

    persist_progress = fn update ->
      update
      |> Map.put("budget", CampaignBudget.snapshot(budget))
      |> persist.()
    end

    try do
      {program, progress} =
        compiled_program(arm, context, metric, budgeted_lm, progress, persist_progress)

      {dev, progress} =
        evaluate_split(program, context.devset, metric, "dev", progress, persist_progress, budget)

      {test, progress} =
        evaluate_split(
          program,
          context.testset,
          metric,
          "test",
          progress,
          persist_progress,
          budget
        )

      reject_if_exhausted!(budget)
      report = Report.fetch(program)

      %{
        "arm" => Atom.to_string(arm),
        "seed" => context.seed,
        "dev" => dev,
        "test" => test,
        "selection_split" => "dev",
        "test_scores_used_for_selection" => false,
        "frozen_test_evaluations" => length(progress["test_rows"] || []),
        "budget" => CampaignBudget.snapshot(budget),
        "optimizer_report" => report && Report.dump(report),
        "program" => progress["program"],
        "scope" => "research_preflight_not_t3"
      }
    after
      :telemetry.detach(telemetry_id)
    end
  end

  defp compiled_program(arm, context, metric, budgeted_lm, progress, persist) do
    case progress["program"] do
      nil ->
        base = program(context.spec, budgeted_lm)
        optimizer_state = progress["optimizer_state"]

        checkpoint_fn = fn state ->
          progress
          |> Map.put("phase", "optimizer")
          |> Map.put("optimizer_state", state)
          |> persist.()
        end

        compiled =
          compile_arm(arm, base, context, metric, budgeted_lm, optimizer_state, checkpoint_fn)

        portable = compiled |> unwrap_budgeted_lm() |> DSEx.Saving.dump()

        progress =
          progress
          |> Map.put("phase", "dev")
          |> Map.put("program", portable)
          |> Map.delete("optimizer_state")

        persist.(progress)
        {compiled, progress}

      state ->
        loaded = state |> DSEx.Saving.load() |> rebind_lm(budgeted_lm)
        {loaded, progress}
    end
  end

  defp compile_arm(:baseline, program, _context, _metric, _lm, _resume, _checkpoint), do: program

  defp compile_arm(:bootstrap_few_shot, program, context, metric, _lm, _resume, _checkpoint) do
    config = arm_config(context, :bootstrap_few_shot)

    metric
    |> BootstrapFewShot.new(max_bootstrapped_demos: fetch!(config, :max_bootstrapped_demos))
    |> BootstrapFewShot.compile(program, context.trainset)
  end

  defp compile_arm(:mipro_v2, program, context, metric, lm, resume, checkpoint) do
    config = arm_config(context, :mipro_v2)

    opts =
      config
      |> keywordize()
      |> Keyword.merge(seed: context.seed, prompt_lm: lm, task_lm: lm, max_concurrency: 1)

    MIPROv2.new(metric, opts)
    |> MIPROv2.compile(program, context.trainset, context.devset,
      resume_state: resume,
      checkpoint_fn: checkpoint
    )
  end

  defp compile_arm(:simba, program, context, metric, lm, resume, checkpoint) do
    config = arm_config(context, :simba)

    opts =
      config
      |> keywordize()
      |> Keyword.merge(seed: context.seed, prompt_lm: lm, max_concurrency: 1)

    SIMBA.new(metric, opts)
    |> SIMBA.compile(program, context.trainset, context.trainset,
      resume_state: resume,
      checkpoint_fn: checkpoint
    )
  end

  defp evaluate_split(program, examples, metric, split, progress, persist, budget) do
    key = split <> "_rows"
    intent_key = split <> "_in_flight"
    rows = progress[key] || []

    if progress[intent_key] do
      intent = progress[intent_key]

      raise ArgumentError,
            "cannot safely resume instruction optimizer #{split} row #{intent["index"]}: a durable dispatch intent has an ambiguous outcome"
    end

    rows =
      examples
      |> Enum.drop(length(rows))
      |> Enum.reduce(rows, fn example, rows ->
        reject_if_exhausted!(budget)
        intent = %{"index" => length(rows), "status" => "dispatch_intent"}

        progress
        |> Map.put("phase", split)
        |> Map.put(key, rows)
        |> Map.put(intent_key, intent)
        |> persist.()

        [trajectory] =
          TrajectoryRunner.run(program, [example], metric, max_concurrency: 1, timeout: :infinity)

        row = %{
          "index" => length(rows),
          "score" => trajectory.score,
          "error" => Report.json_safe(trajectory.error)
        }

        updated = rows ++ [row]

        progress
        |> Map.put("phase", split)
        |> Map.put(key, updated)
        |> Map.delete(intent_key)
        |> persist.()

        updated
      end)

    score = if rows == [], do: 0.0, else: Enum.sum(Enum.map(rows, & &1["score"])) / length(rows)
    {score, progress |> Map.put(key, rows) |> Map.delete(intent_key)}
  end

  defp reject_if_exhausted!(budget) do
    case CampaignBudget.snapshot(budget)["exhausted"] do
      nil -> :ok
      dimension -> raise "campaign budget exhausted: #{dimension}"
    end
  end

  defp program(spec, lm) do
    spec["signature"]
    |> DSEx.signature(spec["instructions"])
    |> DSEx.chain_of_thought(lm: lm, adapter: DSEx.Adapter.Chat, config: [cache: false])
  end

  defp unwrap_budgeted_lm(program) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{
                                                                          name: name,
                                                                          predictor: predictor
                                                                        },
                                                                        acc ->
      inner =
        case predictor.lm do
          %BudgetedLM{inner: inner} -> inner
          other -> other
        end

      DSEx.ProgramParameters.update_predictor(acc, name, &DSEx.Predict.Predict.with_lm(&1, inner))
    end)
  end

  defp rebind_lm(program, lm) do
    Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
      DSEx.ProgramParameters.update_predictor(acc, name, &DSEx.Predict.Predict.with_lm(&1, lm))
    end)
  end

  defp artifact(context, checkpoint) do
    results = checkpoint["completed"]

    %{
      "schema_version" => @schema_version,
      "runner" => "dsex-instruction-optimizer-campaign",
      "evidence_level" => "research_preflight",
      "claim_scope" => "costed one-seed AIME preflight; not T3 effectiveness or parity",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "identity" => context.identity,
      "dataset" => %{
        "family" => context.family,
        "split_counts" => %{
          "train" => length(context.trainset),
          "dev" => length(context.devset),
          "test" => length(context.testset)
        },
        "split_checksums" => split_checksums(context.paths)
      },
      "results" => results,
      "budget_scope" => "per_arm",
      "summary" => %{
        "arms_completed" => Map.keys(results) |> Enum.sort(),
        "all_requested_arms_completed" => map_size(results) == length(context.arms),
        "multi_seed" => false,
        "uncertainty_complete" => false,
        "t3_complete" => false
      }
    }
  end

  defp load_spec!(root, family) do
    root
    |> Path.join("families.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("families")
    |> Enum.find(&(&1["family"] == family))
    |> case do
      nil -> raise ArgumentError, "missing campaign family #{family}"
      spec -> spec
    end
  end

  defp split_paths(root, family) do
    dir = Path.join(root, family)

    %{
      train: Path.join(dir, "train.jsonl"),
      dev: Path.join(dir, "dev.jsonl"),
      test: Path.join(dir, "test.jsonl")
    }
  end

  defp verify_splits!(spec, paths) do
    actual = split_checksums(paths)

    unless actual == spec["split_checksums"] do
      raise ArgumentError, "instruction optimizer dataset split checksum mismatch"
    end
  end

  defp split_checksums(paths) do
    Map.new(paths, fn {name, path} -> {Atom.to_string(name), "sha256:" <> file_sha256(path)} end)
  end

  defp file_sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp validate_arms!(arms) when is_list(arms) do
    arms =
      Enum.map(arms, fn
        arm when is_atom(arm) -> arm
        arm when is_binary(arm) -> String.to_existing_atom(arm)
      end)

    unknown = arms -- @default_arms

    if arms == [] or unknown != [],
      do: raise(ArgumentError, "invalid instruction optimizer arms: #{inspect(arms)}")

    Enum.uniq(arms)
  end

  defp arm_config(context, arm),
    do: Map.get(context.arm_configs, arm, Map.get(context.arm_configs, Atom.to_string(arm), %{}))

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end

  defp keywordize(map),
    do:
      Enum.map(map, fn {key, value} ->
        {if(is_atom(key), do: key, else: String.to_existing_atom(key)), value}
      end)

  defp checkpoint_path(dir, campaign_id, family, seed) do
    name = "#{campaign_id}-#{family}-#{seed}" |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    Path.join(dir, name <> ".json")
  end

  defp load_checkpoint!(path, identity) do
    case File.read(path) do
      {:ok, json} ->
        %{"payload" => payload, "payload_sha256" => checksum} = Jason.decode!(json)

        unless checksum == term_sha256(payload),
          do: raise(ArgumentError, "campaign checkpoint checksum mismatch")

        unless payload["identity"] == identity,
          do: raise(ArgumentError, "campaign checkpoint identity mismatch")

        payload

      {:error, :enoent} ->
        checkpoint = %{"identity" => identity, "completed" => %{}, "in_progress" => %{}}
        write_checkpoint!(path, checkpoint)
        checkpoint
    end
  end

  defp write_checkpoint!(path, checkpoint),
    do:
      write_json_atomic!(path, %{
        "payload_sha256" => term_sha256(checkpoint),
        "payload" => checkpoint
      })

  defp write_json_atomic!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    path
  end

  defp term_sha256(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp git_sha, do: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim()
  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
