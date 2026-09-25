defmodule Mix.Tasks.Imp.Benchmark.Search do
  @moduledoc """
  Write provider-free shared inference-time search evidence.

      mix imp.benchmark.search --out tmp/search-benchmark

  Correctness and bounded-concurrency checks are deterministic. Latency is
  reported as a source-checkout measurement and is never a pass/fail threshold.
  """

  use Mix.Task

  @shortdoc "Run provider-free shared search evidence"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          iterations: :integer,
          max_concurrency: :integer,
          work_ms: :integer
        ]
      )

    if argv != [] or invalid != [], do: Mix.raise("invalid options: #{inspect(argv ++ invalid)}")

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("search"))
    File.mkdir_p!(out_dir)

    artifact =
      Imp.BenchmarkTruth.Search.run(
        iterations: Keyword.get(opts, :iterations, 10),
        num_threads: Keyword.get(opts, :max_concurrency, 2),
        work_ms: Keyword.get(opts, :work_ms, 10)
      )

    path = Path.join(out_dir, "search-source-checkout-#{timestamp_slug()}.json")
    path = Imp.BenchmarkTruth.ArtifactFile.write_json!(path, artifact)

    Mix.shell().info("search benchmark report: #{path}")

    Mix.shell().info(
      "deterministic checks passing: #{artifact["summary"]["passing"]}/#{artifact["summary"]["total"]}"
    )

    unless artifact["summary"]["complete"] do
      Mix.raise("search benchmark checks failed; inspect #{path}")
    end
  end

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
