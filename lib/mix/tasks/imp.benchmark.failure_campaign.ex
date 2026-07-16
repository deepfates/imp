defmodule Mix.Tasks.Imp.Benchmark.FailureCampaign do
  @moduledoc """
  Run the repeated failure and recovery campaign.

      mix imp.benchmark.failure_campaign --iterations 10 --out tmp/failure-campaign
      mix imp.benchmark.failure_campaign --live --live-iterations 2 --require-clean

  The `--live` rows use only local injected transports and a static LM. They
  never contact an external provider or service.
  """

  use Mix.Task

  @shortdoc "Run repeated Imp failure and recovery checks"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          iterations: :integer,
          max_concurrency: :integer,
          iteration_timeout_ms: :integer,
          live: :boolean,
          live_iterations: :integer,
          live_timeout_ms: :integer,
          require_clean: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    live? = Keyword.get(opts, :live, false)

    run_context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, true),
        inputs: %{
          "protocol_id" => "failure_campaign",
          "iterations" => Keyword.get(opts, :iterations, 10),
          "max_concurrency" => Keyword.get(opts, :max_concurrency, 4),
          "iteration_timeout_ms" => Keyword.get(opts, :iteration_timeout_ms, 15_000),
          "live" => live?,
          "live_iterations" => Keyword.get(opts, :live_iterations, 2),
          "live_timeout_ms" => Keyword.get(opts, :live_timeout_ms, 30_000),
          "authority" => "local_injected_transport",
          "external_network" => false
        }
      )

    artifact =
      Imp.BenchmarkTruth.FailureCampaign.run(
        iterations: Keyword.get(opts, :iterations, 10),
        max_concurrency: Keyword.get(opts, :max_concurrency, 4),
        iteration_timeout_ms: Keyword.get(opts, :iteration_timeout_ms, 15_000),
        live: live?,
        live_iterations: Keyword.get(opts, :live_iterations, 2),
        live_timeout_ms: Keyword.get(opts, :live_timeout_ms, 30_000),
        secrets: []
      )

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("failure-recovery"))
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, "failure-campaign-#{timestamp_slug()}.json")

    %{artifact: artifact, path: path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, artifact, run_context)

    Mix.shell().info("failure campaign report: #{path}")

    unless artifact["summary"]["deterministic_complete"] and artifact["runtime"]["leak_free"] and
             (not live? or artifact["summary"]["live_complete"]) do
      Mix.raise("deterministic failure campaign failed; inspect #{path}")
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
  end
end
