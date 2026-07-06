defmodule Mix.Tasks.Dsex.Benchmark.Fetch do
  @moduledoc """
  Fetch canonical benchmark samples.

      mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 20 --out benchmarks/data
      mix dsex.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data
  """

  use Mix.Task

  @shortdoc "Fetch canonical DSEx benchmark truth datasets"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          tasks: :string,
          length: :integer,
          offset: :integer,
          out: :string,
          full: :boolean,
          page_delay_ms: :integer,
          backend: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    tasks = parse_tasks(Keyword.get(opts, :tasks, "gsm8k,hotpotqa"))

    if backend(opts) == "parquet" do
      run_parquet_fetch!(opts, tasks)
    else
      run_rows_fetch!(opts, tasks)
    end
  end

  defp parse_tasks(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp requested_length(opts) do
    if Keyword.get(opts, :full, false), do: :full, else: Keyword.get(opts, :length, 20)
  end

  defp backend(opts) do
    Keyword.get(opts, :backend) || if Keyword.get(opts, :full, false), do: "parquet", else: "rows"
  end

  defp run_rows_fetch!(opts, tasks) do
    results =
      DSEx.BenchmarkTruth.fetch(tasks,
        out_dir: Keyword.get(opts, :out, "benchmarks/data"),
        offset: Keyword.get(opts, :offset, 0),
        length: requested_length(opts),
        page_delay_ms: Keyword.get(opts, :page_delay_ms, 250)
      )

    Enum.each(results, fn
      %{task: task, data_path: data_path, manifest_path: manifest_path} ->
        Mix.shell().info("#{task}: #{data_path} #{manifest_path}")

      {:error, reason} ->
        Mix.raise("benchmark fetch failed: #{inspect(reason)}")
    end)
  end

  defp run_parquet_fetch!(opts, tasks) do
    args =
      [
        "scripts/hf_benchmark_fetch.py",
        "--tasks",
        Enum.join(tasks, ","),
        "--out",
        Keyword.get(opts, :out, "benchmarks/data"),
        "--offset",
        to_string(Keyword.get(opts, :offset, 0))
      ] ++ length_args(opts)

    case System.cmd(python(opts), args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn line -> Mix.shell().info(line) end)

      {output, status} ->
        Mix.raise("parquet benchmark fetch failed with status #{status}:\n#{output}")
    end
  end

  defp length_args(opts) do
    if Keyword.get(opts, :full, false),
      do: ["--full"],
      else: ["--length", to_string(Keyword.get(opts, :length, 20))]
  end

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
  end
end
