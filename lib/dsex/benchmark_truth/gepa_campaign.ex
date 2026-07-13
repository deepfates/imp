defmodule DSEx.BenchmarkTruth.GepaCampaign do
  @moduledoc false

  alias DSEx.Adapter.Chat

  alias DSEx.BenchmarkTruth.{
    ArtifactFile,
    GepaComponentFeedback,
    GepaMetrics,
    HotpotMultiHop,
    HoverBM25,
    HoverMultiHop,
    IFBenchTwoStage,
    Papillon,
    RunContext
  }

  alias DSEx.Optimizer.GEPA

  @required_families DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

  def run(opts) do
    dataset_root = Keyword.fetch!(opts, :dataset_root)
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    model = Keyword.fetch!(opts, :model)
    reflection_model = Keyword.fetch!(opts, :reflection_model)
    out_dir = Keyword.get(opts, :out_dir, "benchmarks/results")
    seeds = Keyword.get(opts, :seeds, [0, 1])

    generation_policy =
      validate_generation_policy!(Keyword.get(opts, :generations, :metric_budget))

    generation_identity = generation_identity(generation_policy)
    pricing_source = Keyword.fetch!(opts, :pricing_source)
    token_cost = Keyword.get(opts, :token_cost)

    run_context =
      Keyword.get_lazy(opts, :run_context, fn ->
        RunContext.new!(source_commits: Keyword.fetch!(opts, :source_commits))
      end)

    source_commits = run_context.source_commits
    validate_source_commits!(source_commits)
    lm = Keyword.fetch!(opts, :lm)
    reflection_lm = Keyword.get(opts, :reflection_lm)
    {judge_lm, judge_model} = judge_config!(opts, lm, model)
    optimizer_callbacks = Keyword.get(opts, :optimizer_callbacks, [])
    families = Keyword.get(opts, :families, @required_families)
    partial? = families != @required_families
    reporter = Keyword.get(opts, :reporter, fn _event -> :ok end)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    execution = Keyword.get(opts, :execution, %{"source" => "library_default"})
    checkpoint_dir = Keyword.get(opts, :checkpoint_dir, Path.join(out_dir, "gepa-checkpoints"))

    File.mkdir_p!(out_dir)
    File.mkdir_p!(checkpoint_dir)
    specs = load_specs!(dataset_root)
    validate_requested_families!(families, specs)

    context = %{
      dataset_root: dataset_root,
      campaign_id: campaign_id,
      model: model,
      reflection_model: reflection_model,
      seeds: seeds,
      generations: generation_policy,
      lm: lm,
      reflection_lm: reflection_lm,
      judge_lm: judge_lm,
      judge_model: judge_model,
      pricing_source: pricing_source,
      reporter: reporter,
      max_concurrency: max_concurrency,
      checkpoint_dir: checkpoint_dir,
      source_commits: source_commits,
      source_git_sha: run_context.code_revision,
      execution: execution,
      optimizer_callbacks: optimizer_callbacks
    }

    rows =
      Enum.map(families, fn family ->
        spec = Map.fetch!(specs, family)
        row(spec, context, explicit_token_cost!(token_cost, family, seeds, families))
      end)
      |> Enum.map(&Map.put(&1, "source_commits", source_commits))

    validate_dsex_rows!(rows, partial?: partial?)

    campaign_contract = %{
      "schema_version" => 1,
      "campaign_id" => campaign_id,
      "model" => model,
      "reflection_model" => reflection_model,
      "judge_model" => judge_model,
      "seeds" => seeds,
      "generations" => generation_identity,
      "max_concurrency" => max_concurrency,
      "pricing_source" => pricing_source,
      "token_cost_schedule_sha256" => term_sha256(token_cost),
      "source_commits" => source_commits,
      "execution" => execution
    }

    report = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-campaign",
      "summary" => %{
        "total" => length(rows),
        "families" => Enum.map(rows, & &1["family"]),
        "partial" => partial?,
        "preflight" => Enum.any?(rows, &(&1["evidence_level"] == "research_preflight")),
        "campaign_id" => campaign_id,
        "model" => model,
        "reflection_model" => reflection_model,
        "seeds" => seeds,
        "generations" => generation_identity,
        "max_concurrency" => max_concurrency,
        "execution" => execution,
        "campaign_contract" => campaign_contract
      },
      "rows" => rows
    }

    out_path = Path.join(out_dir, "dsex-gepa-rows-#{timestamp_slug()}.json")

    %{artifact: report, path: out_path} =
      ArtifactFile.write_run_json!(out_path, report, run_context)

    %{report: report, out_path: out_path}
  end

  defp validate_source_commits!(source_commits) do
    unless DSEx.BenchmarkTruth.GepaReplicationContract.valid_source_commits?(source_commits) do
      raise ArgumentError,
            "source_commits must contain concrete dspy, dsex, and gepa_artifact identities"
    end
  end

  @doc false
  def handle_req_llm_usage_event(_event, measurements, _metadata, usage_agent) do
    Agent.update(usage_agent, &sum_usage(&1, usage_from_measurements(measurements)))
  end

  defp load_specs!(dataset_root) do
    path = Path.join(dataset_root, "families.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("families")
    |> Map.new(fn spec -> {spec["family"], spec} end)
  end

  defp validate_requested_families!(families, specs) do
    unknown = families -- @required_families
    missing_specs = Enum.reject(families, &Map.has_key?(specs, &1))

    cond do
      families == [] ->
        raise ArgumentError, "DSEx GEPA campaign requires at least one family"

      unknown != [] ->
        raise ArgumentError, "unknown DSEx GEPA campaign families: #{Enum.join(unknown, ", ")}"

      missing_specs != [] ->
        raise ArgumentError,
              "DSEx GEPA dataset root missing requested families: #{Enum.join(missing_specs, ", ")}"

      true ->
        :ok
    end
  end

  defp validate_dsex_rows!(rows, opts) do
    families = Enum.map(rows, & &1["family"])
    missing = @required_families -- families

    if not Keyword.get(opts, :partial?, false) and missing != [] do
      raise ArgumentError, "DSEx GEPA campaign rows missing families: #{Enum.join(missing, ", ")}"
    end

    Enum.each(rows, fn row ->
      unless is_map(get_in(row, ["results", "dsex_gepa"])) do
        raise ArgumentError,
              "DSEx GEPA campaign row missing results.dsex_gepa for #{row["family"]}"
      end

      unless row["evidence_level"] in ["research_campaign", "research_preflight"] and
               is_map(row["dataset"]) and is_map(row["token_cost"]) and
               is_map(row["source_commits"]) do
        raise ArgumentError,
              "DSEx GEPA campaign row missing research metadata for #{row["family"]}"
      end

      if row["family"] in ["HotpotQABench", "hoverBench"] do
        retrieval = get_in(row, ["dataset", "retrieval"])

        unless hover_retrieval_provenance?(retrieval) do
          raise ArgumentError,
                "DSEx GEPA #{row["family"]} row requires source-exact BM25/wiki retrieval provenance"
        end
      end
    end)

    :ok
  end

  defp row(spec, context, token_cost) do
    %{
      dataset_root: dataset_root,
      campaign_id: campaign_id,
      model: model,
      reflection_model: reflection_model,
      seeds: seeds,
      generations: generation_policy,
      lm: lm,
      reflection_lm: reflection_lm,
      judge_lm: judge_lm,
      judge_model: judge_model,
      pricing_source: pricing_source,
      reporter: reporter,
      max_concurrency: max_concurrency,
      checkpoint_dir: checkpoint_dir,
      source_commits: source_commits,
      execution: execution,
      optimizer_callbacks: optimizer_callbacks
    } = context

    family = spec["family"]
    program = spec["program"]
    signature = spec["signature"]
    input_keys = spec["input_keys"]
    budget = spec["metric_calls"]
    generations = generation_limit(generation_policy, budget)
    paths = split_paths(dataset_root, family)

    trainset = DSEx.Datasets.jsonl(paths.train, input_keys)
    devset = DSEx.Datasets.jsonl(paths.dev, input_keys)
    testset = DSEx.Datasets.jsonl(paths.test, input_keys)
    validate_family_spec!(spec)

    seed_context = %{
      spec: spec,
      trainset: trainset,
      devset: devset,
      testset: testset,
      lm: lm,
      reflection_lm: reflection_lm,
      judge_lm: judge_lm,
      budget: budget,
      generations: generations,
      max_concurrency: max_concurrency,
      execution: execution,
      optimizer_callbacks: optimizer_callbacks
    }

    report_progress(reporter, %{
      event: :family_start,
      family: family,
      split_counts: %{
        train: length(trainset),
        dev: length(devset),
        test: length(testset)
      },
      seeds: seeds,
      generations: generations,
      max_concurrency: max_concurrency
    })

    checkpoint_path = checkpoint_path(checkpoint_dir, campaign_id, family)

    checkpoint_identity = %{
      "schema_version" => 1,
      "campaign_id" => campaign_id,
      "family" => family,
      "model" => model,
      "reflection_model" => reflection_model,
      "judge_model" => judge_model,
      "seeds" => seeds,
      "generations" => generations,
      "max_concurrency" => max_concurrency,
      "pricing_source" => pricing_source,
      "token_cost" => token_cost,
      "source_commits" => source_commits,
      "execution" => execution,
      "dataset" => %{
        "spec_sha256" => term_sha256(spec),
        "split_checksums" => split_checksums(paths)
      }
    }

    checkpoint = load_checkpoint!(checkpoint_path, checkpoint_identity)

    checkpoint =
      Enum.reduce(seeds, checkpoint, fn seed, checkpoint ->
        case checkpoint_seed(checkpoint, seed) do
          nil ->
            report_progress(reporter, %{event: :seed_start, family: family, seed: seed})
            progress = checkpoint_progress(checkpoint, seed)

            progress_fn = fn seed_progress ->
              updated =
                put_in(checkpoint, ["in_progress", Integer.to_string(seed)], seed_progress)

              write_checkpoint!(checkpoint_path, updated)

              candidates = get_in(seed_progress, ["optimizer_state", "candidates"]) || []

              report_progress(reporter, %{
                event: :seed_checkpoint,
                family: family,
                seed: seed,
                phase: if(candidates == [], do: :baseline, else: :optimizer),
                baseline_splits:
                  seed_progress
                  |> Map.get("baseline", %{})
                  |> Map.keys()
                  |> Enum.sort(),
                completed_generations: max(length(candidates) - 1, 0)
              })

              :ok
            end

            initial_usage = Map.get(progress, "usage", empty_usage())

            persist_usage = fn usage ->
              progress
              |> Map.put("usage", usage)
              |> progress_fn.()
            end

            {wall_us, result, usage} =
              measure_req_llm_usage(
                initial_usage,
                fn usage_fn ->
                  :timer.tc(fn ->
                    run_seed(
                      seed_context,
                      seed,
                      progress,
                      fn seed_progress ->
                        seed_progress
                        |> Map.put("usage", usage_fn.())
                        |> progress_fn.()
                      end
                    )
                  end)
                end,
                persist_usage
              )

            report_progress(reporter, %{
              event: :seed_done,
              family: family,
              seed: seed,
              train: result.train,
              dev: result.dev,
              test: result.test,
              candidate_count: result.candidate_count
            })

            entry = %{
              "seed" => seed,
              "result" => stringify_seed_result(result),
              "wall_us" => wall_us,
              "usage" => usage
            }

            updated =
              checkpoint
              |> update_in(["completed"], &(&1 ++ [entry]))
              |> update_in(["in_progress"], &Map.delete(&1, Integer.to_string(seed)))

            write_checkpoint!(checkpoint_path, updated)
            updated

          _entry ->
            report_progress(reporter, %{event: :seed_resumed, family: family, seed: seed})
            checkpoint
        end
      end)

    entries = Enum.map(seeds, &checkpoint_seed(checkpoint, &1))
    seed_results = Enum.map(entries, &atomize_seed_result(&1["result"]))
    wall_us = Enum.sum(Enum.map(entries, & &1["wall_us"]))
    usage = Enum.reduce(entries, empty_usage(), &sum_usage(&2, &1["usage"]))

    best = Enum.max_by(seed_results, &{&1.dev, -&1.seed})
    budget_complete? = Enum.all?(seed_results, &(&1.optimizer_stop_reason == "max_metric_calls"))

    report_progress(reporter, %{
      event: :family_done,
      family: family,
      selected_seed: best.seed,
      best_dev: best.dev,
      selected_test: best.test,
      wall_clock_ms: max(1, System.convert_time_unit(wall_us, :microsecond, :millisecond))
    })

    %{
      "family" => family,
      "program" => program,
      "campaign_id" => campaign_id,
      "model" => model,
      "reflection_model" => reflection_model,
      "execution" => execution,
      "evidence_level" =>
        if(budget_complete?, do: "research_campaign", else: "research_preflight"),
      "metric_calls" => budget,
      "token_cost" => token_cost!(usage, token_cost, pricing_source, family),
      "optimizer_budgets" => %{
        "baseline" => length(testset),
        "dspy_gepa" => budget,
        "dsex_gepa" => budget,
        "mipro_v2" => budget
      },
      "metric_call_evidence" => metric_call_evidence(best, seed_results),
      "dataset" => %{
        "source" => "DSEx GEPA dataset root #{Path.expand(dataset_root)}",
        "split" => "train_dev_test",
        "scope" => Map.get(spec, "dataset_scope", "unknown"),
        "max_per_split" => spec["max_per_split"],
        "split_counts" => spec["split_counts"],
        "checksums" => split_checksums(paths),
        "retrieval" => retrieval_evidence(spec["retrieval"], execution)
      },
      "wall_clock_ms" => max(1, System.convert_time_unit(wall_us, :microsecond, :millisecond)),
      "seed_variance" => seed_variance(seed_results),
      "seed_selection" => %{
        "dsex_gepa" => %{
          "method" => "best_dev",
          "seeds" => Enum.map(seed_results, & &1.seed),
          "selected_seed" => best.seed,
          "selection_split" => "dev",
          "test_scores_used" => false,
          "source" => "DSEx GEPA campaign completed-seed dev score comparison"
        }
      },
      "train_dev_test_gap" => %{
        "train" => best.train,
        "dev" => best.dev,
        "test" => best.test,
        "split_digests" => split_checksums(paths)
      },
      "results" => %{
        "dsex_gepa" => %{
          "score" => best.test,
          "source" => "DSEx GEPA campaign runner #{context.source_git_sha} #{family}/#{program}",
          "candidate_count" => best.candidate_count,
          "frontier_size" => best.frontier_size,
          "seed" => best.seed
        }
      },
      "metadata" => %{
        "budget_complete" => budget_complete?,
        "generation_policy" => generation_identity(generation_policy),
        "max_iterations" => generations,
        "signature" => signature,
        "instructions" => spec["instructions"],
        "output_key" => spec["output_key"],
        "component_feedback" => best.component_feedback
      }
    }
    |> maybe_put_papillon_judge(spec, judge_model)
  end

  defp report_progress(reporter, event) when is_function(reporter, 1) do
    reporter.(event)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_put_papillon_judge(
         row,
         %{"upstream_metric" => "papillon_utils.compute_overall_score"},
         judge_model
       ) do
    Map.put(row, "metric_judge", %{
      "kind" => "papillon_quality_leakage",
      "model" => judge_model,
      "quality_judge" => "DSEx ChainOfThought JudgeQuality source-faithful pairwise order check",
      "leakage_judge" =>
        "DSEx ChainOfThought JudgeLeakage source-faithful pii leaked-count check",
      "score_formula" => "(quality + (1 - leakage)) / 2.0"
    })
  end

  defp maybe_put_papillon_judge(row, _spec, _judge_model), do: row

  defp hover_retrieval_provenance?(%{
         "kind" => "bm25s_wiki_abstracts_2017",
         "status" => "present",
         "corpus_checksum" => "sha256:" <> corpus_hash,
         "index_checksum" => "sha256:" <> index_hash
       }) do
    byte_size(corpus_hash) == 64 and byte_size(index_hash) == 64
  end

  defp hover_retrieval_provenance?(_other), do: false

  defp retrieval_evidence(nil, _execution), do: nil

  defp retrieval_evidence(retrieval, execution) do
    upstream? = get_in(execution, ["retrieval", "hover_upstream_bm25"]) == true

    Map.merge(retrieval, %{
      "verified" => true,
      "implementation" => if(upstream?, do: "upstream_python_bm25s", else: "dsex_local_bm25")
    })
  end

  defp run_seed(context, seed, progress, progress_fn) do
    %{
      spec: spec,
      trainset: trainset,
      devset: devset,
      testset: testset,
      lm: lm,
      reflection_lm: reflection_lm,
      judge_lm: judge_lm,
      budget: budget,
      generations: generations,
      max_concurrency: max_concurrency,
      execution: execution,
      optimizer_callbacks: optimizer_callbacks
    } = context

    metric = GepaMetrics.metric(spec, judge_lm: judge_lm)
    program = program_for(spec, lm, execution)

    feedback_metric =
      GepaMetrics.metric_with_feedback(spec,
        judge_lm: judge_lm,
        upstream_descriptions: get_in(execution, ["ifbench", "upstream_descriptions"]) == true,
        gepa_root: get_in(execution, ["retrieval", "gepa_root"]),
        python: get_in(execution, ["retrieval", "python"]) || "python3"
      )

    component_feedback =
      GepaComponentFeedback.callbacks!(spec, program, feedback_metric)

    baseline =
      baseline_scores(
        program,
        [train: trainset, dev: devset, test: testset],
        metric,
        max_concurrency,
        progress,
        progress_fn
      )

    optimizer_checkpoint_fn = fn optimizer_state ->
      progress
      |> Map.put("baseline", stringify_scores(baseline))
      |> Map.put("optimizer_state", optimizer_state)
      |> progress_fn.()
    end

    {compiled, report} =
      GEPA.new(metric,
        seed: seed,
        generations: generations,
        max_concurrency: max_concurrency,
        timeout: get_in(execution, ["lm", "optimizer_timeout_ms"]) || 30_000,
        reflection_lm: reflection_lm,
        max_metric_calls: budget,
        callbacks: optimizer_callbacks,
        component_feedback: component_feedback,
        feedback_fn: fn _trainset ->
          "Improve #{spec["family"]} by matching #{spec["output_key"]} exactly. Seed #{seed}."
        end
      )
      |> GEPA.compile_with_report(program, trainset, devset,
        resume_state: progress["optimizer_state"],
        checkpoint_fn: optimizer_checkpoint_fn
      )

    metric_calls = Map.get(report.metadata, :metric_calls)
    metric_call_limit = Map.get(report.metadata, :max_metric_calls)
    stop_reason = Map.get(report.metadata, :stop_reason)

    unless non_negative_integer?(metric_calls) do
      raise ArgumentError, "GEPA optimizer did not export observed metric calls"
    end

    unless metric_call_limit == budget do
      raise ArgumentError,
            "GEPA optimizer budget state did not enforce the family metric-call limit"
    end

    %{
      seed: seed,
      train: score(compiled, trainset, metric, max_concurrency),
      dev: score(compiled, devset, metric, max_concurrency),
      test: score(compiled, testset, metric, max_concurrency),
      baseline_train: baseline.train,
      baseline_dev: baseline.dev,
      baseline_test: baseline.test,
      candidate_count: report.candidate_count,
      frontier_size: Map.get(report.metadata, :frontier_size, 0),
      optimizer_metric_calls: metric_calls,
      optimizer_metric_call_limit: metric_call_limit,
      optimizer_stop_reason: normalize_stop_reason(stop_reason),
      component_feedback:
        component_feedback
        |> GepaComponentFeedback.identity()
        |> maybe_mark_upstream_ifbench_feedback(spec, execution)
    }
  end

  defp maybe_mark_upstream_ifbench_feedback(
         identity,
         %{"program" => "IFBenchCoT2StageProgram"},
         execution
       ) do
    Map.put(
      identity,
      "description_source",
      if(get_in(execution, ["ifbench", "upstream_descriptions"]) == true,
        do: "pinned_upstream_python_registry",
        else: "native_instruction_identity"
      )
    )
  end

  defp maybe_mark_upstream_ifbench_feedback(identity, _spec, _execution), do: identity

  defp judge_config!(opts, lm, model) do
    case Keyword.fetch(opts, :judge_lm) do
      {:ok, judge_lm} -> {judge_lm, Keyword.fetch!(opts, :judge_model)}
      :error -> {lm, model}
    end
  end

  defp metric_call_evidence(best, seed_results) do
    %{
      "basis" => "observed_and_enforced",
      "source" => "DSEx.Optimizer.GEPA report metadata backed by DSEx.Optimizer.GEPA.Budget",
      "observed" => %{"dsex_gepa" => best.optimizer_metric_calls},
      "enforced_limits" => %{"dsex_gepa" => true},
      "per_seed" =>
        Enum.map(seed_results, fn result ->
          %{
            "seed" => result.seed,
            "observed" => result.optimizer_metric_calls,
            "limit" => result.optimizer_metric_call_limit,
            "stop_reason" => result.optimizer_stop_reason
          }
        end)
    }
  end

  defp normalize_stop_reason({:budget_exhausted, :metric_calls, _requested, _limit}),
    do: "max_metric_calls"

  defp normalize_stop_reason(nil), do: nil
  defp normalize_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_stop_reason(reason), do: inspect(reason)

  defp validate_generation_policy!(:metric_budget), do: :metric_budget

  defp validate_generation_policy!(generations)
       when is_integer(generations) and generations > 0,
       do: generations

  defp validate_generation_policy!(generations) do
    raise ArgumentError,
          "generations must be a positive integer or :metric_budget, got: #{inspect(generations)}"
  end

  defp generation_identity(:metric_budget), do: "metric_budget"
  defp generation_identity(generations), do: generations

  defp generation_limit(:metric_budget, metric_budget), do: metric_budget
  defp generation_limit(generations, _metric_budget), do: generations

  defp program_for(
         %{"upstream_metric" => "hover_utils.discrete_retrieval_eval"} = spec,
         lm,
         execution
       ) do
    retrieval = Map.fetch!(spec, "retrieval")

    if get_in(execution, ["retrieval", "hover_upstream_bm25"]) == true do
      HoverMultiHop.new(lm, retrieval, upstream_python: true)
    else
      HoverMultiHop.new(lm, retrieval)
    end
  end

  defp program_for(%{"program" => "HotpotMultiHop"} = spec, lm, execution) do
    retrieval = Map.fetch!(spec, "retrieval")

    if get_in(execution, ["retrieval", "hover_upstream_bm25"]) == true do
      python = get_in(execution, ["retrieval", "python"]) || "python3"
      HotpotMultiHop.integration(lm, retrieval, python: python)
    else
      retriever = HoverBM25.new(retrieval, k: 7)
      HotpotMultiHop.new(lm, retriever)
    end
  end

  defp program_for(%{"program" => "IFBenchCoT2StageProgram"}, lm, _execution) do
    IFBenchTwoStage.new(lm, adapter: Chat)
  end

  defp program_for(%{"program" => "PAPILLON"}, lm, _execution) do
    Papillon.new(lm, lm: lm, adapter: Chat)
  end

  defp program_for(%{"program" => "CoT"} = spec, lm, _execution) do
    spec["signature"]
    |> DSEx.signature(spec["instructions"])
    |> DSEx.chain_of_thought(lm: lm, adapter: Chat)
  end

  defp program_for(spec, _lm, _execution) do
    raise ArgumentError,
          "unsupported GEPA campaign program #{inspect(spec["program"])} for #{inspect(spec["family"])}"
  end

  defp validate_family_spec!(%{"upstream_metric" => "hover_utils.discrete_retrieval_eval"} = spec) do
    unless hover_retrieval_provenance?(spec["retrieval"]) do
      raise ArgumentError,
            "DSEx GEPA hoverBench row requires source-exact BM25/wiki retrieval provenance"
    end

    DSEx.BenchmarkTruth.HoverBM25.verify_source!(spec["retrieval"])
  end

  defp validate_family_spec!(%{"program" => "HotpotMultiHop"} = spec) do
    unless hover_retrieval_provenance?(spec["retrieval"]) do
      raise ArgumentError,
            "DSEx GEPA HotpotQABench row requires source-exact BM25/wiki retrieval provenance"
    end

    DSEx.BenchmarkTruth.HoverBM25.verify_source!(spec["retrieval"])
  end

  defp validate_family_spec!(_spec), do: :ok

  defp checkpoint_path(checkpoint_dir, campaign_id, family) do
    name =
      "#{campaign_id}-#{family}"
      |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")

    Path.join(checkpoint_dir, name <> ".json")
  end

  defp load_checkpoint!(path, identity) do
    case File.read(path) do
      {:ok, contents} ->
        checkpoint = decode_checkpoint!(contents, path)

        unless checkpoint["identity"] == identity do
          raise ArgumentError,
                "DSEx GEPA checkpoint configuration or dataset identity mismatch: #{path}"
        end

        validate_checkpoint!(checkpoint, identity, path)

      {:error, :enoent} ->
        %{"identity" => identity, "completed" => [], "in_progress" => %{}}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read GEPA checkpoint", path: path
    end
  end

  defp checkpoint_seed(checkpoint, seed) do
    Enum.find(checkpoint["completed"], &(&1["seed"] == seed))
  end

  defp checkpoint_progress(checkpoint, seed) do
    checkpoint
    |> Map.get("in_progress", %{})
    |> Map.get(Integer.to_string(seed), %{})
  end

  defp decode_checkpoint!(contents, path) do
    Jason.decode!(contents)
  rescue
    error in Jason.DecodeError ->
      reraise ArgumentError,
              [message: "invalid GEPA checkpoint JSON #{path}: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp validate_checkpoint!(%{"completed" => completed} = checkpoint, identity, path)
       when is_list(completed) do
    requested_seeds = Map.fetch!(identity, "seeds")
    seeds = Enum.map(completed, &checkpoint_entry_seed!(&1, requested_seeds, path))

    if length(seeds) != length(Enum.uniq(seeds)),
      do: raise(ArgumentError, "duplicate seed entries in GEPA checkpoint: #{path}")

    validate_in_progress!(Map.get(checkpoint, "in_progress", %{}), requested_seeds, seeds, path)

    Map.put_new(checkpoint, "in_progress", %{})
  end

  defp validate_checkpoint!(_checkpoint, _identity, path),
    do: raise(ArgumentError, "invalid GEPA checkpoint structure: #{path}")

  defp checkpoint_entry_seed!(entry, requested_seeds, path) when is_map(entry) do
    seed = entry["seed"]
    result = entry["result"]
    usage = entry["usage"]

    unless seed in requested_seeds and is_map(result) and result["seed"] == seed and
             positive_integer?(entry["wall_us"]) and valid_seed_result?(result) and
             valid_usage?(usage) do
      raise ArgumentError, "invalid seed entry in GEPA checkpoint: #{path}"
    end

    seed
  end

  defp checkpoint_entry_seed!(_entry, _requested_seeds, path),
    do: raise(ArgumentError, "invalid seed entry in GEPA checkpoint: #{path}")

  defp validate_in_progress!(in_progress, requested_seeds, completed_seeds, path)
       when is_map(in_progress) do
    Enum.each(in_progress, fn {seed_string, progress} ->
      with {seed, ""} <- Integer.parse(seed_string),
           true <- seed in requested_seeds,
           false <- seed in completed_seeds,
           true <- valid_seed_progress?(progress) do
        :ok
      else
        _ -> raise ArgumentError, "invalid in-progress seed in GEPA checkpoint: #{path}"
      end
    end)
  end

  defp validate_in_progress!(_in_progress, _requested_seeds, _completed_seeds, path),
    do: raise(ArgumentError, "invalid GEPA checkpoint in_progress structure: #{path}")

  defp valid_seed_progress?(progress) when is_map(progress) do
    baseline = progress["baseline"]
    optimizer_state = progress["optimizer_state"]
    usage = progress["usage"]

    (is_nil(baseline) or valid_baseline_progress?(baseline)) and
      (is_nil(optimizer_state) or
         (valid_baseline_scores?(baseline) and is_map(optimizer_state))) and
      (is_nil(usage) or valid_usage?(usage))
  end

  defp valid_seed_progress?(_progress), do: false

  defp valid_baseline_scores?(baseline) when is_map(baseline) do
    Enum.all?(["train", "dev", "test"], fn split ->
      numeric?(baseline[split]) and baseline[split] >= 0 and baseline[split] <= 1
    end)
  end

  defp valid_baseline_scores?(_baseline), do: false

  defp valid_baseline_progress?(baseline) when is_map(baseline) do
    keys = baseline |> Map.keys() |> MapSet.new()

    keys in [
      MapSet.new(["train"]),
      MapSet.new(["train", "dev"]),
      MapSet.new(["train", "dev", "test"])
    ] and
      Enum.all?(baseline, fn {_split, score} -> numeric?(score) and score >= 0 and score <= 1 end)
  end

  defp valid_baseline_progress?(_baseline), do: false

  defp valid_seed_result?(result) do
    Enum.all?(
      ["train", "dev", "test", "baseline_train", "baseline_dev", "baseline_test"],
      &(numeric?(result[&1]) and result[&1] >= 0 and result[&1] <= 1)
    ) and non_negative_integer?(result["candidate_count"]) and
      non_negative_integer?(result["frontier_size"]) and
      non_negative_integer?(result["optimizer_metric_calls"]) and
      positive_integer?(result["optimizer_metric_call_limit"]) and
      result["optimizer_metric_calls"] <= result["optimizer_metric_call_limit"] and
      valid_component_feedback?(result["component_feedback"])
  end

  defp valid_component_feedback?(%{
         "contract" => "DSEx.Optimizer.GEPA.ComponentFeedback/v1",
         "components" => components,
         "strict" => true
       })
       when is_list(components) do
    components == Enum.sort(Enum.uniq(components)) and
      Enum.all?(components, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp valid_component_feedback?(_feedback), do: false

  defp valid_usage?(usage) when is_map(usage) do
    numeric?(usage["usd"]) and usage["usd"] >= 0 and
      non_negative_integer?(usage["input_tokens"]) and
      non_negative_integer?(usage["output_tokens"])
  end

  defp valid_usage?(_usage), do: false

  defp numeric?(value), do: is_integer(value) or is_float(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp write_checkpoint!(path, checkpoint) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, Jason.encode!(checkpoint, pretty: true) <> "\n", [:sync])
    File.rename!(temporary, path)
  end

  defp stringify_seed_result(result) do
    result |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp stringify_scores(scores) do
    %{"train" => scores.train, "dev" => scores.dev, "test" => scores.test}
  end

  defp stringify_partial_scores(scores) do
    Map.new(scores, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp atomize_seed_result(result) do
    %{
      seed: Map.fetch!(result, "seed"),
      train: Map.fetch!(result, "train"),
      dev: Map.fetch!(result, "dev"),
      test: Map.fetch!(result, "test"),
      candidate_count: Map.fetch!(result, "candidate_count"),
      frontier_size: Map.fetch!(result, "frontier_size"),
      baseline_train: Map.fetch!(result, "baseline_train"),
      baseline_dev: Map.fetch!(result, "baseline_dev"),
      baseline_test: Map.fetch!(result, "baseline_test"),
      optimizer_metric_calls: Map.fetch!(result, "optimizer_metric_calls"),
      optimizer_metric_call_limit: Map.fetch!(result, "optimizer_metric_call_limit"),
      optimizer_stop_reason: Map.get(result, "optimizer_stop_reason"),
      component_feedback: Map.fetch!(result, "component_feedback")
    }
  end

  defp term_sha256(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp measure_req_llm_usage(initial_usage, fun, failure_fn) do
    handler_id = {__MODULE__, :req_llm_usage, make_ref()}
    {:ok, usage_agent} = Agent.start_link(fn -> initial_usage end)

    :telemetry.attach(
      handler_id,
      [:req_llm, :token_usage],
      &__MODULE__.handle_req_llm_usage_event/4,
      usage_agent
    )

    try do
      {wall_us, seed_results} = fun.(fn -> Agent.get(usage_agent, & &1) end)
      {wall_us, seed_results, Agent.get(usage_agent, & &1)}
    rescue
      error ->
        failure_fn.(Agent.get(usage_agent, & &1))
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        failure_fn.(Agent.get(usage_agent, & &1))
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      :telemetry.detach(handler_id)
      Agent.stop(usage_agent)
    end
  end

  defp empty_usage, do: %{"usd" => 0.0, "input_tokens" => 0, "output_tokens" => 0}

  defp usage_from_measurements(measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    %{
      "usd" => usage_number(measurements, [:total_cost, :cost]),
      "input_tokens" => trunc(usage_number(tokens, [:input_tokens, :input])),
      "output_tokens" => trunc(usage_number(tokens, [:output_tokens, :output]))
    }
  end

  defp sum_usage(left, right) do
    %{
      "usd" => left["usd"] + right["usd"],
      "input_tokens" => left["input_tokens"] + right["input_tokens"],
      "output_tokens" => left["output_tokens"] + right["output_tokens"]
    }
  end

  defp explicit_token_cost!(nil, _family, _seeds, _families), do: nil

  defp explicit_token_cost!(token_cost, family, seeds, families) when is_map(token_cost) do
    if cost_tuple?(token_cost) do
      if length(families) == 1 and length(seeds) == 1 do
        validate_cost_tuple!(token_cost, "explicit token cost")
      else
        raise ArgumentError,
              "multi-family or multi-seed GEPA campaigns require token_cost keyed by family and seed"
      end
    else
      seed_costs =
        case Map.fetch(token_cost, family) do
          {:ok, costs} when is_map(costs) -> costs
          _ -> raise ArgumentError, "missing explicit token costs for GEPA family #{family}"
        end

      expected_seed_keys = Enum.map(seeds, &Integer.to_string/1)

      unless Map.keys(seed_costs) |> Enum.sort() == Enum.sort(expected_seed_keys) do
        raise ArgumentError,
              "explicit token costs for #{family} must exactly match seeds #{inspect(seeds)}"
      end

      breakdown =
        Enum.map(seeds, fn seed ->
          cost =
            validate_cost_tuple!(seed_costs[Integer.to_string(seed)], "#{family} seed #{seed}")

          Map.put(cost, "seed", seed)
        end)

      breakdown
      |> Enum.reduce(empty_usage(), &sum_usage(&2, &1))
      |> Map.put("breakdown", breakdown)
    end
  end

  defp explicit_token_cost!(token_cost, _family, _seeds, _families) do
    raise ArgumentError, "token_cost must be nil or a map; got: #{inspect(token_cost)}"
  end

  defp cost_tuple?(cost),
    do: Enum.all?(["usd", "input_tokens", "output_tokens"], &Map.has_key?(cost, &1))

  defp validate_cost_tuple!(cost, context) when is_map(cost) do
    unless numeric?(cost["usd"]) and cost["usd"] >= 0 and
             non_negative_integer?(cost["input_tokens"]) and
             non_negative_integer?(cost["output_tokens"]) do
      raise ArgumentError, "invalid #{context}: expected non-negative usd and token counts"
    end

    Map.take(cost, ["usd", "input_tokens", "output_tokens"])
  end

  defp validate_cost_tuple!(_cost, context),
    do: raise(ArgumentError, "invalid #{context}: expected a cost map")

  defp token_cost!(usage, token_cost, pricing_source, family) do
    zero_usage? =
      usage["usd"] <= 0 and usage["input_tokens"] == 0 and usage["output_tokens"] == 0

    cond do
      zero_usage? and is_map(token_cost) ->
        Map.put(token_cost, "pricing_source", pricing_source)

      zero_usage? and family == "hoverBench" ->
        %{
          "usd" => 0.0,
          "input_tokens" => 0,
          "output_tokens" => 0,
          "pricing_source" =>
            "#{pricing_source}; deterministic HoVer BM25 row emitted no ReqLLM calls"
        }

      zero_usage? ->
        raise ArgumentError,
              "DSEx GEPA #{family} row requires ReqLLM usage telemetry or explicit token_cost"

      usage["usd"] > 0 and usage["input_tokens"] > 0 and usage["output_tokens"] > 0 ->
        Map.put(usage, "pricing_source", pricing_source)

      true ->
        raise ArgumentError,
              "ReqLLM usage telemetry did not include positive cost and token counts"
    end
  end

  defp usage_number(map, keys) do
    keys
    |> Enum.find_value(0, fn key ->
      value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
      if is_number(value), do: value
    end)
  end

  defp score(program, examples, metric, max_concurrency) do
    DSEx.Evaluate.run(
      DSEx.Evaluate.new(examples, metric,
        max_errors: :infinity,
        max_concurrency: max_concurrency,
        timeout: :infinity
      ),
      program
    ).score
  end

  defp baseline_scores(program, splits, metric, max_concurrency, progress, progress_fn) do
    Enum.reduce(splits, %{}, fn {split, examples}, scores ->
      key = Atom.to_string(split)

      value =
        case get_in(progress, ["baseline", key]) do
          nil ->
            value = score(program, examples, metric, max_concurrency)
            baseline = scores |> Map.put(split, value) |> stringify_partial_scores()
            progress_fn.(Map.put(progress, "baseline", baseline))
            value

          checkpointed ->
            checkpointed
        end

      Map.put(scores, split, value)
    end)
  end

  defp split_paths(dataset_root, family) do
    family_dir = Path.join(dataset_root, family)

    %{
      train: Path.join(family_dir, "train.jsonl"),
      dev: Path.join(family_dir, "dev.jsonl"),
      test: Path.join(family_dir, "test.jsonl")
    }
  end

  defp split_checksums(paths) do
    %{
      "train" => "sha256:" <> file_sha256(paths.train),
      "dev" => "sha256:" <> file_sha256(paths.dev),
      "test" => "sha256:" <> file_sha256(paths.test)
    }
  end

  defp seed_variance(seed_results) do
    scores = Enum.map(seed_results, & &1.test)
    mean = Enum.sum(scores) / max(length(scores), 1)
    variance = Enum.sum(Enum.map(scores, &:math.pow(&1 - mean, 2))) / max(length(scores), 1)

    %{
      "seeds" => Enum.map(seed_results, & &1.seed),
      "mean" => mean,
      "stddev" => :math.sqrt(variance)
    }
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace("Z", "Z")
  end
end
