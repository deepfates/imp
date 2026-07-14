defmodule Mix.Tasks.Imp.Benchmark.OptimizeAnything do
  @moduledoc """
  Validate and emit Optimize Anything replication evidence.

      mix imp.benchmark.optimize_anything --input path/to/rows.json --out benchmarks/results
      mix imp.benchmark.optimize_anything --smoke --out tmp/optimize-anything
      mix imp.benchmark.optimize_anything --live --provider openai \
        --model gpt-5.4-2026-03-05 --seeds 17,23,31 --out benchmarks/results

  Input mode requires complete live evidence for every artifact class. Smoke
  mode emits deterministic local rows that validate the evidence pipeline but
  explicitly do not authorize effectiveness claims.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.ArtifactFile
  alias Imp.BenchmarkTruth.OptimizeAnything.{Artifact, Campaign}

  @shortdoc "Validate Optimize Anything replication evidence"
  @default_out_dir "benchmarks/results"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse_options!(args)
    input = Keyword.get(opts, :input)
    smoke? = Keyword.get(opts, :smoke, false)
    live? = Keyword.get(opts, :live, false)
    validate_source!(input, smoke?, live?)

    if live? do
      run_live(opts)
    else
      run_artifact_mode(opts, input, smoke?)
    end
  end

  defp run_artifact_mode(opts, input, smoke?) do
    rows = if smoke?, do: smoke_rows(), else: read_rows!(input)
    mode = if(smoke?, do: :smoke, else: :full)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    artifact =
      Artifact.build(rows,
        mode: mode,
        git_sha: git_sha(),
        source: if(smoke?, do: %{"mode" => "smoke"}, else: input_source(input))
      )

    path = Path.join(out_dir, "optimize-anything-replication-#{timestamp_slug()}.json")
    path = ArtifactFile.write_json!(path, artifact)
    Mix.shell().info("Optimize Anything replication artifact: #{path}")

    unless get_in(artifact, ["summary", "all_passing"]) do
      Mix.raise("Optimize Anything replication artifact is incomplete; inspect #{path}")
    end
  end

  defp parse_options!(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          out: :string,
          smoke: :boolean,
          live: :boolean,
          provider: :string,
          model: :string,
          seeds: :string,
          max_proposals: :integer
        ]
      )

    if invalid != [] or argv != [],
      do: Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}")

    opts
  end

  defp validate_source!(input, smoke?, live?) do
    if Enum.count([not is_nil(input), smoke?, live?], & &1) != 1 do
      Mix.raise("exactly one of --input, --smoke, or --live is required")
    end
  end

  defp run_live(opts) do
    provider = Keyword.get(opts, :provider) || Mix.raise("--provider is required for --live")
    model = Keyword.get(opts, :model) || Mix.raise("--model is required for --live")
    seeds = opts |> Keyword.get(:seeds, "0,1,2") |> parse_seeds!()

    %{out_path: path} =
      Campaign.run(
        lm: Imp.req_llm("#{provider}:#{model}"),
        provider: provider,
        model: model,
        seeds: seeds,
        max_proposals: Keyword.get(opts, :max_proposals, 3),
        out_dir: Keyword.get(opts, :out, @default_out_dir)
      )

    Mix.shell().info("Optimize Anything live campaign artifact: #{path}")
  end

  defp parse_seeds!(value) do
    seeds =
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn seed ->
        case Integer.parse(String.trim(seed)) do
          {parsed, ""} -> parsed
          _ -> Mix.raise("--seeds must be a comma-separated integer list")
        end
      end)

    if length(seeds) >= 3 and Enum.uniq(seeds) == seeds,
      do: seeds,
      else: Mix.raise("--seeds must contain at least three distinct integers")
  end

  defp read_rows!(path) do
    case path |> File.read!() |> Jason.decode!() do
      rows when is_list(rows) ->
        rows

      %{"rows" => rows} when is_list(rows) ->
        rows

      value ->
        Mix.raise(
          "Optimize Anything input must be a row list or an object with rows, got: #{inspect(value)}"
        )
    end
  end

  defp smoke_rows do
    Artifact.artifact_classes()
    |> Enum.with_index()
    |> Enum.map(fn {artifact_class, index} -> smoke_row(artifact_class, index) end)
  end

  defp smoke_row(artifact_class, index) do
    baseline_score = 0.5
    optimized_score = 0.6

    %{
      "artifact_class" => artifact_class,
      "evaluator_id" => "local/#{artifact_class}/smoke-v1",
      "baseline" => %{"artifact" => "baseline #{artifact_class}", "score" => baseline_score},
      "optimized" => %{"artifact" => "optimized #{artifact_class}", "score" => optimized_score},
      "comparator" => nil,
      "absolute_lift" => optimized_score - baseline_score,
      "relative_lift" => (optimized_score - baseline_score) / baseline_score,
      "metric_calls" => 2,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "provider" => "local",
      "model" => "deterministic-smoke-v1",
      "cost_usd" => 0.0,
      "wall_time_ms" => 0,
      "seed" => index,
      "train_count" => 2,
      "val_count" => 2,
      "train_digest" => digest("#{artifact_class}:train"),
      "val_digest" => digest("#{artifact_class}:validation"),
      "provenance" => %{
        "run_id" => "smoke-#{artifact_class}-#{index}",
        "checkpoint" => "in-memory-smoke",
        "git_sha" => git_sha()
      },
      "status" => "smoke",
      "effectiveness_authorized" => false,
      "reproducibility" => %{
        "command" => "mix imp.benchmark.optimize_anything --smoke",
        "evaluator_version" => "smoke-v1",
        "dataset_source" => "embedded deterministic smoke fixture",
        "environment" => "local BEAM smoke",
        "source_commits" => %{"imp" => git_sha()}
      }
    }
  end

  defp input_source(path) do
    %{"mode" => "input", "path" => path, "sha256" => digest(File.read!(path))}
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--verify", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
