defmodule Mix.Tasks.Imp.Benchmark.MultimodalQuality do
  @moduledoc """
  Plan or run the provider-backed multimodal quality campaign.

      mix imp.benchmark.multimodal_quality --plan
      mix imp.benchmark.multimodal_quality --profile openai-responses --live

  Plan and dry-run modes validate the signed manifest and every asset without
  reading credentials or dispatching provider requests. Live mode uses only the
  credential environment variable pinned by the manifest.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.ArtifactFile
  alias Imp.BenchmarkTruth.MultimodalRunner

  @shortdoc "Plan or run the live multimodal quality campaign"
  @profiles %{
    "google" => "benchmarks/data/multimodal/manifest.json",
    "openai-responses" => "benchmarks/data/multimodal/openai-responses-manifest.json"
  }

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          checkpoint: :string,
          dry_run: :boolean,
          live: :boolean,
          manifest: :string,
          max_concurrency: :integer,
          out: :string,
          plan: :boolean,
          profile: :string
        ]
      )

    if invalid != [] or argv != [],
      do: Mix.raise("invalid arguments: #{inspect(invalid ++ argv)}")

    mode = mode!(opts)
    manifest = manifest_path!(opts)
    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("multimodal"))

    runner_opts =
      [
        manifest: manifest,
        max_concurrency: Keyword.get(opts, :max_concurrency, 2),
        mode: mode
      ]
      |> maybe_put(:checkpoint, Keyword.get(opts, :checkpoint))
      |> maybe_put_live_credential(mode, manifest)

    artifact = MultimodalRunner.run(runner_opts)
    File.mkdir_p!(out_dir)

    path =
      ArtifactFile.write_json!(
        Path.join(out_dir, "multimodal-quality-#{mode}-#{timestamp_slug()}.json"),
        artifact
      )

    Mix.shell().info("multimodal quality report: #{path}")

    Mix.shell().info("provider dispatches this run: #{artifact["summary"]["dispatched"]}")
    Mix.shell().info("checkpoint rows resumed: #{artifact["summary"]["resumed"]}")

    Mix.shell().info("quality claim: #{artifact["claims"]["multimodal_quality"]}")

    if mode == :live and not artifact["claims"]["multimodal_quality"] do
      Mix.raise("multimodal quality thresholds did not pass")
    end
  end

  defp mode!(opts) do
    plan? = Keyword.get(opts, :plan, false) or Keyword.get(opts, :dry_run, false)
    live? = Keyword.get(opts, :live, false)

    case {plan?, live?} do
      {true, false} -> :plan
      {false, true} -> :live
      _ -> Mix.raise("choose exactly one of --plan/--dry-run or --live")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_live_credential(opts, :plan, _manifest), do: opts

  defp maybe_put_live_credential(opts, :live, manifest_path) do
    manifest = Imp.BenchmarkTruth.MultimodalManifest.load!(manifest_path)
    env = manifest.payload["provider"]["credential_env"]

    case System.fetch_env(env) do
      {:ok, api_key} when api_key != "" -> Keyword.put(opts, :api_key, api_key)
      _ -> Mix.raise("#{env} is required for --live and is read only from the task process")
    end
  end

  defp manifest_path!(opts) do
    case {Keyword.get(opts, :manifest), Keyword.fetch(opts, :profile)} do
      {manifest, :error} when is_binary(manifest) ->
        manifest

      {nil, :error} ->
        Map.fetch!(@profiles, "google")

      {nil, {:ok, profile}} ->
        Map.get(@profiles, profile) || Mix.raise("unknown profile #{inspect(profile)}")

      {_manifest, {:ok, _profile}} ->
        Mix.raise("choose --manifest or --profile, not both")
    end
  end

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
