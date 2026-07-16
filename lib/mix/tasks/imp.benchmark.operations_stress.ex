defmodule Mix.Tasks.Imp.Benchmark.OperationsStress do
  @moduledoc """
  Run the test-only structured I/O and operations stress diagnostic.

  This single-process check is not source-bound evidence and is ineligible for
  C0-C5 claim admission.

      mix imp.benchmark.operations_stress --out tmp/operations-stress
  """

  use Mix.Task

  @shortdoc "Run test-only structured I/O and operations diagnostics"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          max_concurrency: :integer
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, Imp.BenchmarkTruth.Paths.runs("operations"))
    File.mkdir_p!(out_dir)

    artifact =
      Imp.BenchmarkTruth.OperationsStress.run(
        max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online())
      )

    out_path = Path.join(out_dir, "operations-stress-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(artifact, pretty: true) <> "\n")

    Mix.shell().info("test-only operations stress diagnostic: #{out_path}")

    Mix.shell().info(
      "checks passing: #{artifact["summary"]["passing"]}/#{artifact["summary"]["total"]}"
    )

    unless artifact["summary"]["complete"] do
      Mix.raise("operations stress checks failed")
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace("Z", "Z")
  end
end
