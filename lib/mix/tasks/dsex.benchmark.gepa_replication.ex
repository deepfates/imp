defmodule Mix.Tasks.Dsex.Benchmark.GepaReplication do
  @moduledoc """
  Validate and emit GEPA paper-replication evidence artifacts.

      mix dsex.benchmark.gepa_replication --input path/to/rows.json --out tmp/gepa-replication

  The task does not fabricate benchmark results. It packages fresh GEPA
  replication rows produced by a campaign runner into the dashboard contract and
  fails unless every row includes the optimizer, budget, cost, seed, and split
  metadata needed for paper-level GEPA claims.
  """

  use Mix.Task

  @shortdoc "Validate GEPA paper-replication rows"

  @default_out_dir "benchmarks/results"

  @required_families [
    "AIMEBench",
    "HotpotQABench",
    "hoverBench",
    "IFBench",
    "LiveBenchMathBench",
    "Papillon"
  ]

  @optimizer_fields ["baseline", "dspy_gepa", "dsex_gepa", "mipro_v2"]
  @required_fields [
    "metric_calls",
    "token_cost",
    "wall_clock_ms",
    "seed_variance",
    "train_dev_test_gap"
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          out: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input = Keyword.get(opts, :input) || Mix.raise("--input is required")
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    rows =
      input
      |> File.read!()
      |> Jason.decode!()
      |> normalize_rows!()

    validation = validate_rows(rows)
    passing = validation.missing_families == [] and validation.missing_fields == []

    artifact = %{
      "schema_version" => 1,
      "runner" => "dsex-gepa-replication",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "source" => %{
        "input" => input,
        "input_sha256" => file_sha256(input),
        "families_required" => @required_families
      },
      "summary" => %{
        "total" => length(rows),
        "passing" => if(passing, do: length(rows), else: 0),
        "all_passing" => passing,
        "full_gepa_replication" => passing,
        "missing_families" => validation.missing_families,
        "missing_fields" => validation.missing_fields
      },
      "rows" => rows
    }

    out_path = Path.join(out_dir, "gepa-replication-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(artifact, pretty: true) <> "\n")
    Mix.shell().info("GEPA replication artifact: #{out_path}")

    unless passing do
      Mix.raise("GEPA replication artifact is incomplete; inspect #{out_path}")
    end
  end

  defp normalize_rows!(%{"rows" => rows}) when is_list(rows), do: rows
  defp normalize_rows!(rows) when is_list(rows), do: rows

  defp normalize_rows!(other) do
    Mix.raise(
      "GEPA replication input must be a list of rows or a map with \"rows\", got: #{inspect(other)}"
    )
  end

  defp validate_rows(rows) do
    present_families = rows |> Enum.map(& &1["family"]) |> Enum.uniq()

    %{
      missing_families: @required_families -- present_families,
      missing_fields:
        rows
        |> Enum.flat_map(fn row ->
          (@optimizer_fields ++ @required_fields)
          |> Enum.reject(&present_field?(row, &1))
          |> Enum.map(&%{"family" => row["family"], "field" => &1})
        end)
    }
  end

  defp present_field?(row, field) when field in @optimizer_fields do
    row
    |> Map.get("results", %{})
    |> Map.get(field)
    |> is_map()
  end

  defp present_field?(row, field), do: Map.has_key?(row, field)

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace("Z", "Z")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
