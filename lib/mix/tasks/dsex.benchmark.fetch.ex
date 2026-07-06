defmodule Mix.Tasks.Dsex.Benchmark.Fetch do
  @moduledoc """
  Fetch canonical benchmark samples.

      mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 20 --out benchmarks/data
  """

  use Mix.Task

  @shortdoc "Fetch canonical DSEx benchmark truth datasets"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [tasks: :string, length: :integer, offset: :integer, out: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    tasks = parse_tasks(Keyword.get(opts, :tasks, "gsm8k,hotpotqa"))

    results =
      DSEx.BenchmarkTruth.fetch(tasks,
        out_dir: Keyword.get(opts, :out, "benchmarks/data"),
        offset: Keyword.get(opts, :offset, 0),
        length: Keyword.get(opts, :length, 20)
      )

    Enum.each(results, fn result ->
      Mix.shell().info("#{result.task}: #{result.data_path} #{result.manifest_path}")
    end)
  end

  defp parse_tasks(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end
end
