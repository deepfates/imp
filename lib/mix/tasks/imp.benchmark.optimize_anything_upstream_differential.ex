defmodule Mix.Tasks.Imp.Benchmark.OptimizeAnythingUpstreamDifferential do
  @moduledoc """
  Verify or run the pinned Optimize Anything matched differential.

      mix imp.benchmark.optimize_anything_upstream_differential
      mix imp.benchmark.optimize_anything_upstream_differential --live --env-file .env
      mix imp.benchmark.optimize_anything_upstream_differential --live --admit --env-file .env
      mix imp.benchmark.optimize_anything_upstream_differential --live \
        --domains circle_packing_26 --seeds 0

  The default command is provider-free. `--live` runs both the public Python
  authority and Imp with the fixed model and controls in the protocol manifest.
  A live run is a capture by default. `--admit` additionally requires the
  independently observed repository to be committed and clean. A domain or
  seed subset is a preflight and cannot satisfy the full protocol.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferential

  @shortdoc "Run the pinned Optimize Anything upstream differential"
  @default_manifest "benchmarks/config/optimize-anything-upstream-differential-v1.json"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    opts = parse_options!(args)
    common = common_options(opts)

    if Keyword.get(opts, :live, false) do
      run_live(opts, common)
    else
      run_provider_free(common)
    end
  end

  defp run_provider_free(opts) do
    case UpstreamDifferential.verify_evaluators(opts) do
      {:error, reason} ->
        Mix.raise("Optimize Anything evaluator verification is not ready: #{reason}")

      artifact ->
        out =
          Keyword.get(
            opts,
            :out,
            Path.join(
              Imp.BenchmarkTruth.Paths.runs("optimize-anything-upstream-differential"),
              "provider-free-evaluator-verification.json"
            )
          )

        path = Imp.BenchmarkTruth.ArtifactFile.write_json!(out, artifact)
        Mix.shell().info("Optimize Anything provider-free evaluator verification: #{path}")
    end
  end

  defp run_live(opts, common) do
    env_files = Keyword.get_values(opts, :env_file)
    Imp.BenchmarkEnv.load_files!(if(env_files == [], do: [".env"], else: env_files))
    manifest = common[:manifest] |> File.read!() |> Jason.decode!()
    controls = manifest["controls"]
    model = controls["model"]

    lm =
      Imp.req_llm(model["imp_name"],
        temperature: model["temperature"],
        max_tokens: model["max_tokens"],
        cache: false
      )

    campaign_opts =
      common
      |> Keyword.put(:lm, lm)
      |> maybe_put(:domains, parse_csv(Keyword.get(opts, :domains)))
      |> maybe_put(:seeds, parse_seeds(Keyword.get(opts, :seeds)))
      |> maybe_put(:run_dir, Keyword.get(opts, :run_dir))
      |> maybe_put(:runtime_timeout, Keyword.get(opts, :runtime_timeout))

    artifact = UpstreamDifferential.run(campaign_opts)
    bundle_sha256 = get_in(artifact, ["bundle_receipt", "sha256"])

    unless is_binary(bundle_sha256) and bundle_sha256 =~ ~r/\A[0-9a-f]{64}\z/ do
      Mix.raise("Optimize Anything live run did not produce a content-addressed evidence bundle")
    end

    out =
      Keyword.get(
        opts,
        :out,
        Path.join(
          Imp.BenchmarkTruth.Paths.runs("optimize-anything-upstream-differential"),
          "matched-live-#{bundle_sha256}.json"
        )
      )

    path = Imp.BenchmarkTruth.ArtifactFile.write_json!(out, artifact)

    Mix.shell().info("Optimize Anything self-contained matched live evidence bundle: #{path}")

    if Keyword.get(opts, :admit, false) do
      UpstreamDifferential.admit_artifact!(artifact, common)

      Mix.shell().info(
        "Optimize Anything source-bound admission: admitted from a clean source tree"
      )
    else
      Mix.shell().info(
        "Optimize Anything source-bound admission: not attempted; this output is capture-only"
      )
    end

    unless artifact["summary"]["execution_complete"] do
      Mix.raise("Optimize Anything matched live differential did not complete")
    end

    unless artifact["summary"]["protocol_complete"] do
      Mix.shell().info(
        "Result is a bounded preflight; the full three-domain, three-seed protocol remains open."
      )
    end
  end

  defp parse_options!(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          live: :boolean,
          admit: :boolean,
          manifest: :string,
          python: :string,
          runner: :string,
          out: :string,
          run_dir: :string,
          domains: :string,
          seeds: :string,
          runtime_timeout: :integer,
          env_file: :keep
        ]
      )

    if argv != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(argv ++ invalid)}")
    end

    opts
  end

  defp common_options(opts) do
    [
      manifest: Path.expand(Keyword.get(opts, :manifest, @default_manifest)),
      python:
        Path.expand(Keyword.get(opts, :python, "tmp/optimize-anything-upstream/.venv/bin/python")),
      runner:
        Path.expand(
          Keyword.get(opts, :runner, "scripts/optimize_anything_upstream_differential.py")
        )
    ]
    |> maybe_put(:out, Keyword.get(opts, :out))
  end

  defp parse_csv(nil), do: nil

  defp parse_csv(value) do
    values = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if values != [] and Enum.all?(values, &(&1 != "")),
      do: values,
      else: Mix.raise("--domains is empty")
  end

  defp parse_seeds(nil), do: nil

  defp parse_seeds(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn seed ->
      case Integer.parse(String.trim(seed)) do
        {parsed, ""} -> parsed
        _ -> Mix.raise("--seeds must be a comma-separated integer list")
      end
    end)
  end

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
