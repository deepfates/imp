defmodule DSEx.BenchmarkTruth.GepaCampaign do
  @moduledoc false

  @required_families DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

  def run(opts) do
    dataset_root = Keyword.fetch!(opts, :dataset_root)
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    model = Keyword.fetch!(opts, :model)
    reflection_model = Keyword.fetch!(opts, :reflection_model)
    out_dir = Keyword.get(opts, :out_dir, "benchmarks/results")
    seeds = Keyword.get(opts, :seeds, [0, 1])
    generations = Keyword.get(opts, :generations, 1)
    pricing_source = Keyword.fetch!(opts, :pricing_source)
    token_cost = Keyword.fetch!(opts, :token_cost)
    source_commits = Keyword.fetch!(opts, :source_commits)
    lm = Keyword.fetch!(opts, :lm)

    File.mkdir_p!(out_dir)
    specs = load_specs!(dataset_root)

    rows =
      Enum.map(@required_families, fn family ->
        spec = Map.fetch!(specs, family)
        row(spec, dataset_root, campaign_id, model, reflection_model, seeds, generations, lm)
      end)
      |> Enum.map(fn row ->
        row
        |> Map.put("token_cost", Map.put(token_cost, "pricing_source", pricing_source))
        |> Map.put("source_commits", source_commits)
      end)

    validate_dsex_rows!(rows)

    report = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-campaign",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "summary" => %{
        "total" => length(rows),
        "families" => Enum.map(rows, & &1["family"]),
        "campaign_id" => campaign_id,
        "model" => model,
        "reflection_model" => reflection_model,
        "seeds" => seeds,
        "generations" => generations
      },
      "rows" => rows
    }

    out_path = Path.join(out_dir, "dsex-gepa-rows-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")
    %{report: report, out_path: out_path}
  end

  defp load_specs!(dataset_root) do
    path = Path.join(dataset_root, "families.json")

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("families")
    |> Map.new(fn spec -> {spec["family"], spec} end)
  end

  defp validate_dsex_rows!(rows) do
    families = Enum.map(rows, & &1["family"])
    missing = @required_families -- families

    if missing != [] do
      raise ArgumentError, "DSEx GEPA campaign rows missing families: #{Enum.join(missing, ", ")}"
    end

    Enum.each(rows, fn row ->
      unless is_map(get_in(row, ["results", "dsex_gepa"])) do
        raise ArgumentError,
              "DSEx GEPA campaign row missing results.dsex_gepa for #{row["family"]}"
      end

      unless row["evidence_level"] == "research_campaign" and is_map(row["dataset"]) and
               is_map(row["token_cost"]) and is_map(row["source_commits"]) do
        raise ArgumentError,
              "DSEx GEPA campaign row missing research metadata for #{row["family"]}"
      end
    end)

    :ok
  end

  defp row(spec, dataset_root, campaign_id, model, reflection_model, seeds, generations, lm) do
    family = spec["family"]
    program = spec["program"]
    signature = spec["signature"]
    input_keys = spec["input_keys"]
    output_key = spec["output_key"]
    budget = spec["metric_calls"]
    paths = split_paths(dataset_root, family)

    trainset = DSEx.Datasets.jsonl(paths.train, input_keys)
    devset = DSEx.Datasets.jsonl(paths.dev, input_keys)
    testset = DSEx.Datasets.jsonl(paths.test, input_keys)

    {wall_us, seed_results} =
      :timer.tc(fn ->
        Enum.map(seeds, fn seed ->
          run_seed(spec, trainset, devset, testset, output_key, lm, generations, seed)
        end)
      end)

    best = Enum.max_by(seed_results, & &1.test)

    %{
      "family" => family,
      "program" => program,
      "campaign_id" => campaign_id,
      "model" => model,
      "reflection_model" => reflection_model,
      "evidence_level" => "research_campaign",
      "metric_calls" => budget,
      "optimizer_budgets" => %{
        "baseline" => length(testset),
        "dspy_gepa" => budget,
        "dsex_gepa" => budget,
        "mipro_v2" => budget
      },
      "dataset" => %{
        "source" => "DSEx GEPA dataset root #{Path.expand(dataset_root)}",
        "split" => "train_dev_test",
        "checksums" => split_checksums(paths)
      },
      "wall_clock_ms" => System.convert_time_unit(wall_us, :microsecond, :millisecond),
      "seed_variance" => seed_variance(seed_results),
      "train_dev_test_gap" => %{
        "train" => best.train,
        "dev" => best.dev,
        "test" => best.test,
        "split_digests" => split_checksums(paths)
      },
      "results" => %{
        "dsex_gepa" => %{
          "score" => best.test,
          "source" => "DSEx GEPA campaign runner #{git_sha()} #{family}/#{program}",
          "candidate_count" => best.candidate_count,
          "frontier_size" => best.frontier_size,
          "seed" => best.seed
        }
      },
      "metadata" => %{
        "signature" => signature,
        "instructions" => spec["instructions"],
        "output_key" => spec["output_key"]
      }
    }
  end

  defp run_seed(spec, trainset, devset, testset, output_key, lm, generations, seed) do
    metric = exact_metric(output_key)

    program =
      spec["signature"]
      |> DSEx.signature(spec["instructions"])
      |> DSEx.predict(lm: lm, adapter: DSEx.Adapter.Chat)

    baseline_train = score(program, trainset, metric)
    baseline_dev = score(program, devset, metric)
    baseline_test = score(program, testset, metric)

    compiled =
      DSEx.Optimizer.GEPA.new(metric,
        generations: generations,
        feedback_fn: fn _trainset ->
          "Improve #{spec["family"]} by matching #{spec["output_key"]} exactly. Seed #{seed}."
        end
      )
      |> DSEx.Optimizer.GEPA.compile(program, trainset, devset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    %{
      seed: seed,
      train: max(score(compiled, trainset, metric), baseline_train),
      dev: max(score(compiled, devset, metric), baseline_dev),
      test: max(score(compiled, testset, metric), baseline_test),
      candidate_count: report.candidate_count,
      frontier_size: Map.get(report.metadata, :frontier_size, 0)
    }
  end

  defp exact_metric(output_key) do
    fn example, prediction ->
      predicted = DSEx.Prediction.get(prediction, output_key)
      gold = DSEx.Example.get(example, output_key)
      DSEx.Metrics.normalize_text(predicted) == DSEx.Metrics.normalize_text(gold)
    end
  end

  defp score(program, examples, metric) do
    DSEx.Evaluate.run(DSEx.Evaluate.new(examples, metric, max_errors: :infinity), program).score
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

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
