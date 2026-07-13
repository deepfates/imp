defmodule Mix.Tasks.Dsex.Benchmark.FailureCampaign do
  @moduledoc """
  Run the repeated provider-free failure and recovery campaign.

      mix dsex.benchmark.failure_campaign --iterations 10 --out tmp/failure-campaign
  """

  use Mix.Task

  @shortdoc "Run repeated DSEx failure and recovery checks"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, iterations: :integer, max_concurrency: :integer]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    artifact =
      DSEx.BenchmarkTruth.FailureCampaign.run(
        iterations: Keyword.get(opts, :iterations, 10),
        max_concurrency: Keyword.get(opts, :max_concurrency, 4)
      )

    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    File.mkdir_p!(out_dir)
    path = Path.join(out_dir, "failure-campaign-#{timestamp_slug()}.json")
    File.write!(path, Jason.encode!(artifact, pretty: true) <> "\n")
    Mix.shell().info("failure campaign report: #{path}")

    unless artifact["summary"]["local_complete"] and artifact["runtime"]["leak_free"] do
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
