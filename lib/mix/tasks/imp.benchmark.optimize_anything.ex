defmodule Mix.Tasks.Imp.Benchmark.OptimizeAnything do
  @moduledoc """
  Validate and emit Optimize Anything replication evidence.

      mix imp.benchmark.optimize_anything --input path/to/rows.json --out benchmarks/runs/optimize-anything
      mix imp.benchmark.optimize_anything --smoke --out tmp/optimize-anything
      mix imp.benchmark.optimize_anything --live --provider openai \
        --model gpt-5.4-2026-03-05 --seeds 17,23,31 \
        --pricing-profile openai-gpt-5.4-standard-2026-03-05 \
        --max-cost-usd 0.50 --max-requests 20 \
        --max-input-tokens 100000 --max-output-tokens 20000 \
        --max-output-tokens-per-request 1000 \
        --out benchmarks/runs/optimize-anything

  Input mode requires complete live evidence for every artifact class. Smoke
  mode emits deterministic local rows that validate the evidence pipeline but
  explicitly do not authorize effectiveness claims.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.ArtifactFile
  alias Imp.BenchmarkTruth.OptimizeAnything.{Artifact, Campaign}
  alias Imp.BenchmarkTruth.OptimizeAnything.PricingPolicy

  @shortdoc "Validate Optimize Anything replication evidence"
  @default_out_dir Imp.BenchmarkTruth.Paths.runs("optimize-anything")
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
          max_proposals: :integer,
          pricing_profile: :string,
          input_price_per_million: :float,
          output_price_per_million: :float,
          pricing_source_url: :string,
          max_cost_usd: :float,
          max_requests: :integer,
          max_input_tokens: :integer,
          max_output_tokens: :integer,
          max_output_tokens_per_request: :integer
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
    pricing = pricing_config!(opts, provider, model)
    limits = live_limits!(opts)

    max_output_tokens_per_request =
      required_positive_integer!(opts, :max_output_tokens_per_request)

    %{out_path: path} =
      Campaign.run(
        lm:
          Imp.req_llm("#{provider}:#{model}",
            cache: false,
            max_retries: 0,
            max_tokens: max_output_tokens_per_request
          ),
        provider: provider,
        model: model,
        seeds: seeds,
        max_proposals: Keyword.get(opts, :max_proposals, 3),
        limits: limits,
        pricing: pricing.pricing,
        pricing_profile: pricing.profile,
        pricing_source_url: pricing.source_url,
        max_output_tokens_per_request: max_output_tokens_per_request,
        out_dir: Keyword.get(opts, :out, @default_out_dir)
      )

    Mix.shell().info("Optimize Anything live campaign artifact: #{path}")
  end

  defp pricing_config!(opts, provider, model) do
    profile = Keyword.get(opts, :pricing_profile)

    custom_fields = [
      Keyword.get(opts, :input_price_per_million),
      Keyword.get(opts, :output_price_per_million),
      Keyword.get(opts, :pricing_source_url)
    ]

    case {profile, Enum.any?(custom_fields, &(not is_nil(&1)))} do
      {profile, false} when is_binary(profile) ->
        pricing_policy!(fn -> PricingPolicy.profile!(provider, model, profile) end)

      {nil, true} ->
        input = required_positive_number!(opts, :input_price_per_million)
        output = required_positive_number!(opts, :output_price_per_million)

        source_url =
          Keyword.get(opts, :pricing_source_url) ||
            Mix.raise("--pricing-source-url is required with custom pricing")

        pricing_policy!(fn ->
          PricingPolicy.custom!(
            provider,
            model,
            %{"input_per_million" => input, "output_per_million" => output},
            source_url
          )
        end)

      {nil, false} ->
        Mix.raise(
          "--pricing-profile or all of --input-price-per-million, " <>
            "--output-price-per-million, and --pricing-source-url are required for --live"
        )

      {_unknown, true} ->
        Mix.raise("--pricing-profile cannot be combined with custom pricing inputs")

      {unknown, false} ->
        Mix.raise("unknown --pricing-profile #{inspect(unknown)}")
    end
  end

  defp live_limits!(opts) do
    %{
      requests: required_positive_integer!(opts, :max_requests),
      input_tokens: required_positive_integer!(opts, :max_input_tokens),
      output_tokens: required_positive_integer!(opts, :max_output_tokens),
      usd: required_positive_number!(opts, :max_cost_usd)
    }
  end

  defp required_positive_integer!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> Mix.raise("--#{option_name(key)} is required and must be a positive integer")
    end
  end

  defp required_positive_number!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_number(value) and value > 0 -> value
      _ -> Mix.raise("--#{option_name(key)} is required and must be positive")
    end
  end

  defp option_name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp pricing_policy!(fun) do
    fun.()
  rescue
    error in ArgumentError -> Mix.raise(Exception.message(error))
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
