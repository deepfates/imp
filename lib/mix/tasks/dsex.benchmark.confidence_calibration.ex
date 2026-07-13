defmodule Mix.Tasks.Dsex.Benchmark.ConfidenceCalibration do
  use Mix.Task

  @shortdoc "Runs held-out raw-confidence and conditional calibration evidence"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          data: :string,
          provenance: :string,
          model: :string,
          out: :string,
          max_concurrency: :integer,
          bins: :integer,
          min_bin_size: :integer
        ]
      )

    api_key = System.get_env("OPENAI_API_KEY") || Mix.raise("OPENAI_API_KEY is required")

    artifact =
      DSEx.BenchmarkTruth.ConfidenceCalibration.run(
        data: opts[:data] || "benchmarks/data/confidence-calibration-trec-fine.jsonl",
        provenance:
          opts[:provenance] ||
            "benchmarks/data/confidence-calibration-trec-fine.provenance.json",
        model: opts[:model] || "openai:gpt-4.1-mini-2025-04-14",
        api_key: api_key,
        max_concurrency: opts[:max_concurrency] || 4,
        bins: opts[:bins] || 10,
        min_bin_size: opts[:min_bin_size] || 5
      )

    out = opts[:out] || "benchmarks/results"
    File.mkdir_p!(out)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    path = Path.join(out, "confidence-calibration-live-#{stamp}.json")
    File.write!(path, [Jason.encode_to_iodata!(artifact, pretty: true), "\n"])
    Mix.shell().info("confidence calibration report: #{path}")
  end
end
