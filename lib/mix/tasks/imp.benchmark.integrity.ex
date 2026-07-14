defmodule Mix.Tasks.Imp.Benchmark.Integrity do
  @moduledoc """
  Check normalized benchmark JSONL files for data-integrity issues.

      mix imp.benchmark.integrity --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl
  """

  use Mix.Task

  @shortdoc "Check benchmark data integrity"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          gsm8k: :string,
          hotpotqa: :string,
          out: :string,
          require_clean: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    tasks = tasks(opts)
    if tasks == [], do: Mix.raise("provide at least one dataset path with --gsm8k or --hotpotqa")

    result =
      Imp.BenchmarkTruth.integrity(tasks,
        out_dir: Keyword.get(opts, :out, "benchmarks/results")
      )

    Mix.shell().info("benchmark data integrity report: #{result.out_path}")
    Mix.shell().info("passing: #{result.report["passing"]}")

    if Keyword.get(opts, :require_clean, false) and not result.report["passing"] do
      Mix.raise("benchmark data integrity check failed; inspect #{result.out_path}")
    end
  end

  defp tasks(opts) do
    []
    |> maybe_put(:gsm8k, Keyword.get(opts, :gsm8k))
    |> maybe_put(:hotpotqa, Keyword.get(opts, :hotpotqa))
  end

  defp maybe_put(tasks, _task, nil), do: tasks
  defp maybe_put(tasks, task, path), do: [{task, path} | tasks] |> Enum.reverse()
end
