defmodule Mix.Tasks.Imp.Benchmark.GepaMerge do
  @moduledoc """
  Merge independently produced Imp GEPA family chunks into one validated input.

      mix imp.benchmark.gepa_merge chunk-a.json chunk-b.json --out benchmarks/results

  Every required family must occur exactly once. The task rejects capped or smoke
  datasets and campaign chunks whose canonical campaign contracts disagree.
  """

  use Mix.Task

  @shortdoc "Merge full-scope Imp GEPA family chunks"

  @impl true
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: [out: :string])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    if paths == [], do: Mix.raise("at least one GEPA chunk path is required")

    chunks = Enum.map(paths, &read_chunk!/1)
    rows = Enum.flat_map(chunks, & &1["rows"])
    validate_families!(rows)
    validate_rows!(rows)
    validate_matching_summaries!(chunks)

    first = hd(chunks)
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    File.mkdir_p!(out_dir)

    artifact = %{
      "schema_version" => first["schema_version"],
      "runner" => "imp-gepa-chunk-merge",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "source_chunks" => Enum.map(paths, &source_chunk/1),
      "summary" =>
        first["summary"]
        |> Map.put("families", required_families())
        |> Map.put("partial", false)
        |> Map.put("merged", true)
        |> Map.put("total", length(rows)),
      "rows" => Enum.sort_by(rows, &family_order(&1["family"]))
    }

    out_path = Path.join(out_dir, "imp-gepa-merged-#{timestamp_slug()}.json")
    out_path = Imp.BenchmarkTruth.ArtifactFile.write_json!(out_path, artifact)
    Mix.shell().info("Merged Imp GEPA rows: #{out_path}")
  end

  defp read_chunk!(path) do
    case path |> File.read!() |> Jason.decode!() do
      %{
        "schema_version" => 1,
        "runner" => "imp-gepa-campaign",
        "rows" => rows,
        "summary" => %{"campaign_contract" => contract} = summary
      } = chunk
      when is_list(rows) and is_map(summary) and is_map(contract) ->
        chunk

      _ ->
        Mix.raise("#{path} is not a schema-valid Imp GEPA campaign chunk")
    end
  end

  defp validate_families!(rows) do
    actual = Enum.map(rows, & &1["family"])
    duplicates = actual -- Enum.uniq(actual)
    missing = required_families() -- actual
    unknown = Enum.uniq(actual) -- required_families()

    if duplicates != [], do: Mix.raise("duplicate GEPA families: #{join(duplicates)}")
    if missing != [], do: Mix.raise("missing GEPA families: #{join(missing)}")
    if unknown != [], do: Mix.raise("unknown GEPA families: #{join(unknown)}")
  end

  defp validate_rows!(rows) do
    Enum.each(rows, fn row ->
      family = row["family"] || "unknown"
      dataset = row["dataset"] || %{}
      counts = dataset["split_counts"] || %{}

      unless dataset["scope"] == "full" and is_nil(dataset["max_per_split"]),
        do: Mix.raise("#{family} is not an uncapped full-scope dataset")

      unless Enum.all?(["train", "dev", "test"], &(is_integer(counts[&1]) and counts[&1] > 1)),
        do: Mix.raise("#{family} does not contain real train/dev/test split counts")

      unless get_in(row, ["seed_variance", "seeds"]) == [0, 1],
        do: Mix.raise("#{family} must contain seeds 0 and 1")
    end)
  end

  defp validate_matching_summaries!(chunks) do
    contracts = chunks |> Enum.map(&get_in(&1, ["summary", "campaign_contract"])) |> Enum.uniq()

    if length(contracts) != 1 do
      Mix.raise("GEPA chunks disagree on canonical campaign contract")
    end

    contract = hd(contracts)

    required = [
      "schema_version",
      "campaign_id",
      "model",
      "reflection_model",
      "judge_model",
      "seeds",
      "generations",
      "max_concurrency",
      "pricing_source",
      "token_cost_schedule_sha256",
      "source_commits",
      "execution"
    ]

    missing = Enum.reject(required, &Map.has_key?(contract, &1))
    if missing != [], do: Mix.raise("GEPA campaign contract missing: #{join(missing)}")

    Enum.each(chunks, fn chunk ->
      summary = chunk["summary"]

      unless Enum.all?(
               [
                 "campaign_id",
                 "model",
                 "reflection_model",
                 "seeds",
                 "generations",
                 "max_concurrency",
                 "execution"
               ],
               &(summary[&1] == contract[&1])
             ) do
        Mix.raise("GEPA chunk summary disagrees with its canonical campaign contract")
      end

      Enum.each(chunk["rows"], fn row ->
        unless row["campaign_id"] == contract["campaign_id"] and
                 row["model"] == contract["model"] and
                 row["reflection_model"] == contract["reflection_model"] and
                 row["execution"] == contract["execution"] and
                 row["source_commits"] == contract["source_commits"] do
          Mix.raise("GEPA row identity disagrees with canonical campaign contract")
        end
      end)
    end)
  end

  defp source_chunk(path) do
    chunk = path |> File.read!() |> Jason.decode!()

    %{
      "path" => path,
      "campaign_id" => get_in(chunk, ["summary", "campaign_contract", "campaign_id"]),
      "git_sha" => chunk["git_sha"],
      "generated_at" => chunk["generated_at"],
      "sha256" =>
        "sha256:" <> (:crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower))
    }
  end

  defp required_families, do: Imp.BenchmarkTruth.GepaReplicationContract.required_families()
  defp family_order(family), do: Enum.find_index(required_families(), &(&1 == family))
  defp join(values), do: values |> Enum.uniq() |> Enum.join(", ")

  defp timestamp_slug do
    Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
