defmodule Mix.Tasks.Dsex.Benchmark.GepaDataset do
  @moduledoc """
  Export GEPA artifact benchmark splits into DSEx GEPA campaign dataset format.

      mix dsex.benchmark.gepa_dataset \\
        --gepa-root path/to/gepa-artifact \\
        --out benchmarks/data/gepa-campaign

  The command imports the upstream GEPA artifact benchmark classes, preserves
  their train/dev/test split construction, and writes the `families.json` plus
  per-family JSONL files consumed by `mix dsex.benchmark.gepa_campaign`.
  """

  use Mix.Task

  @shortdoc "Export GEPA artifact family splits for DSEx campaigns"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          gepa_root: :string,
          out: :string,
          python: :string,
          max_per_split: :integer
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    gepa_root = Keyword.get(opts, :gepa_root) || Mix.raise("--gepa-root is required")
    out = Keyword.get(opts, :out, "benchmarks/data/gepa-campaign")
    python = Keyword.get(opts, :python, "python3")

    args =
      [
        "scripts/gepa_export_dataset_root.py",
        "--gepa-root",
        gepa_root,
        "--out",
        out
      ] ++ max_per_split_args(opts)

    case System.cmd(python, args, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(String.trim(output))

      {output, status} ->
        Mix.raise("GEPA dataset export failed with status #{status}:\n#{output}")
    end
  end

  defp max_per_split_args(opts) do
    case Keyword.get(opts, :max_per_split) do
      nil -> []
      count -> ["--max-per-split", to_string(count)]
    end
  end
end
