defmodule Mix.Tasks.Dsex.Benchmark.ConfidenceCalibration do
  use Mix.Task

  @shortdoc "Runs held-out live confidence calibration and prompt-drift evidence"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, [], []} =
      OptionParser.parse(args,
        strict: [data: :string, model: :string, out: :string, max_concurrency: :integer]
      )

    api_key = System.get_env("OPENAI_API_KEY") || Mix.raise("OPENAI_API_KEY is required")

    artifact =
      DSEx.BenchmarkTruth.ConfidenceCalibration.run(
        data: opts[:data] || "benchmarks/data/confidence-calibration.jsonl",
        model: opts[:model] || "openai:gpt-4o-mini",
        api_key: api_key,
        max_concurrency: opts[:max_concurrency] || 2
      )

    out = opts[:out] || "benchmarks/results"
    File.mkdir_p!(out)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    path = Path.join(out, "confidence-calibration-live-#{stamp}.json")
    File.write!(path, Jason.encode_to_iodata!(artifact, pretty: true))
    Mix.shell().info("confidence calibration report: #{path}")
  end
end
