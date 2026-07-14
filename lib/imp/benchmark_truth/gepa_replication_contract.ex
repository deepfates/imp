defmodule Imp.BenchmarkTruth.GepaReplicationContract do
  @moduledoc false

  @required_families [
    "AIMEBench",
    "HotpotQABench",
    "hoverBench",
    "IFBench",
    "LiveBenchMathBench",
    "Papillon"
  ]

  @optimizer_fields ["baseline", "dspy_gepa", "imp_gepa", "mipro_v2"]
  @source_commit_fields ["dspy", "imp", "gepa_artifact"]

  @research_fields [
    "campaign_id",
    "dataset",
    "evidence_level",
    "metric_call_evidence",
    "metric_calls",
    "optimizer_budgets",
    "seed_selection",
    "source_commits",
    "token_cost",
    "wall_clock_ms",
    "seed_variance",
    "train_dev_test_gap"
  ]

  @smoke_fields [
    "metric_calls",
    "token_cost",
    "wall_clock_ms",
    "seed_variance",
    "train_dev_test_gap"
  ]

  def required_families, do: @required_families
  def optimizer_fields, do: @optimizer_fields
  def research_fields, do: @research_fields

  @doc false
  def valid_source_commits?(commits) when is_map(commits) do
    Map.keys(commits) |> Enum.sort() == Enum.sort(@source_commit_fields) and
      Enum.all?(@source_commit_fields, &concrete_source?(commits[&1]))
  end

  def valid_source_commits?(_commits), do: false

  def validate_rows(rows, opts \\ []) when is_list(rows) do
    mode = Keyword.get(opts, :mode, :research)

    required_fields =
      @optimizer_fields ++ if(mode == :smoke, do: @smoke_fields, else: @research_fields)

    present_families = rows |> Enum.map(& &1["family"]) |> Enum.uniq()
    family_counts = Enum.frequencies(Enum.map(rows, & &1["family"]))

    duplicate_families =
      family_counts
      |> Enum.filter(fn {_family, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    unknown_families = present_families -- @required_families

    missing_fields =
      rows
      |> Enum.flat_map(fn row ->
        required_fields
        |> Enum.reject(&present_field?(row, &1, mode))
        |> Enum.map(&%{"family" => row["family"], "field" => &1})
      end)
      |> Kernel.++(papillon_judge_missing_fields(rows, mode))

    %{
      missing_families: @required_families -- present_families,
      duplicate_families: duplicate_families,
      unknown_families: unknown_families,
      missing_fields: missing_fields,
      passing:
        missing_fields == [] and @required_families -- present_families == [] and
          duplicate_families == [] and unknown_families == [] and
          length(rows) == length(@required_families)
    }
  end

  def full_artifact?(artifact) when is_map(artifact) do
    rows = Map.get(artifact, "rows", [])
    validation = validate_rows(rows, mode: :research)

    validation.passing and
      artifact["runner"] == "imp-gepa-replication" and
      get_in(artifact, ["source", "mode"]) == "input" and
      get_in(artifact, ["summary", "all_passing"]) == true and
      get_in(artifact, ["summary", "full_gepa_replication"]) == true and
      get_in(artifact, ["summary", "evidence_level"]) == "research_campaign"
  end

  def full_artifact?(_artifact), do: false

  defp present_field?(row, field, :smoke) when field in @optimizer_fields do
    row |> Map.get("results", %{}) |> Map.get(field) |> is_map()
  end

  defp present_field?(row, field, _mode) when field in @optimizer_fields do
    result = row |> Map.get("results", %{}) |> Map.get(field)

    is_map(result) and numeric?(result["score"]) and concrete_source?(result["source"])
  end

  defp present_field?(row, "dataset", :smoke) do
    dataset = Map.get(row, "dataset")

    is_map(dataset) and concrete_source?(dataset["source"]) and
      dataset["split"] in ["train", "dev", "test", "train_dev_test"] and
      is_map(dataset["checksums"]) and map_size(dataset["checksums"]) > 0
  end

  defp present_field?(row, "dataset", _mode) do
    dataset = Map.get(row, "dataset")

    is_map(dataset) and concrete_source?(dataset["source"]) and
      dataset["split"] in ["train", "dev", "test", "train_dev_test"] and
      dataset["scope"] == "full" and is_nil(dataset["max_per_split"]) and
      full_split_counts?(dataset["split_counts"]) and is_map(dataset["checksums"]) and
      map_size(dataset["checksums"]) > 0 and research_retrieval_valid?(row, dataset)
  end

  defp present_field?(row, "evidence_level", _mode),
    do: row["evidence_level"] == "research_campaign"

  defp present_field?(row, "source_commits", _mode) do
    valid_source_commits?(Map.get(row, "source_commits"))
  end

  defp present_field?(row, "optimizer_budgets", _mode) do
    budgets = Map.get(row, "optimizer_budgets")

    is_map(budgets) and Enum.all?(@optimizer_fields, &positive_integer?(budgets[&1]))
  end

  defp present_field?(row, "metric_call_evidence", _mode) do
    evidence = row["metric_call_evidence"]
    observed = if(is_map(evidence), do: evidence["observed"], else: nil)
    enforced_limits = if(is_map(evidence), do: evidence["enforced_limits"], else: nil)
    budgets = row["optimizer_budgets"]

    is_map(evidence) and evidence["basis"] == "observed_and_enforced" and
      concrete_source?(evidence["source"]) and is_map(observed) and is_map(enforced_limits) and
      is_map(budgets) and
      Enum.all?(@optimizer_fields, fn optimizer ->
        positive_integer?(observed[optimizer]) and enforced_limits[optimizer] == true and
          positive_integer?(budgets[optimizer]) and observed[optimizer] <= budgets[optimizer]
      end)
  end

  defp present_field?(row, "metric_calls", _mode), do: positive_integer?(row["metric_calls"])
  defp present_field?(row, "wall_clock_ms", :smoke), do: is_integer(row["wall_clock_ms"])
  defp present_field?(row, "wall_clock_ms", _mode), do: positive_integer?(row["wall_clock_ms"])

  defp present_field?(row, "token_cost", :smoke), do: is_map(row["token_cost"])

  defp present_field?(row, "token_cost", _mode) do
    cost = row["token_cost"]

    is_map(cost) and numeric?(cost["usd"]) and cost["usd"] > 0 and
      positive_integer?(cost["input_tokens"]) and positive_integer?(cost["output_tokens"]) and
      concrete_source?(cost["pricing_source"])
  end

  defp present_field?(row, "seed_variance", :smoke), do: is_map(row["seed_variance"])

  defp present_field?(row, "seed_variance", _mode) do
    variance = row["seed_variance"]
    seeds = if(is_map(variance), do: variance["seeds"], else: nil)

    is_map(variance) and is_list(seeds) and length(Enum.uniq(seeds)) >= 2 and
      numeric?(variance["stddev"])
  end

  defp present_field?(row, "seed_selection", _mode) do
    selections = row["seed_selection"]
    declared_seeds = get_in(row, ["seed_variance", "seeds"])

    is_map(selections) and is_list(declared_seeds) and
      Enum.all?(@optimizer_fields, fn optimizer ->
        selection = selections[optimizer]

        honest_seed_selection?(selection) and
          Enum.sort(selection["seeds"]) == Enum.sort(declared_seeds)
      end)
  end

  defp present_field?(row, "train_dev_test_gap", :smoke), do: is_map(row["train_dev_test_gap"])

  defp present_field?(row, "train_dev_test_gap", _mode) do
    gap = row["train_dev_test_gap"]

    is_map(gap) and numeric?(gap["train"]) and numeric?(gap["dev"]) and numeric?(gap["test"]) and
      distinct_split_digests?(gap)
  end

  defp present_field?(row, field, _mode), do: concrete_source?(row[field])

  defp research_retrieval_valid?(%{"family" => family}, dataset)
       when family in ["HotpotQABench", "hoverBench"] do
    retrieval = dataset["retrieval"]

    is_map(retrieval) and retrieval["verified"] == true and
      retrieval["implementation"] == "upstream_python_bm25s" and
      concrete_sha256?(retrieval["corpus_checksum"]) and
      concrete_sha256?(retrieval["index_checksum"])
  end

  defp research_retrieval_valid?(_row, _dataset), do: true

  defp concrete_sha256?("sha256:" <> digest), do: byte_size(digest) == 64
  defp concrete_sha256?(_value), do: false

  defp papillon_judge_missing_fields(_rows, :smoke), do: []

  defp papillon_judge_missing_fields(rows, _mode) do
    rows
    |> Enum.filter(&(&1["family"] == "Papillon"))
    |> Enum.reject(&papillon_judge_present?/1)
    |> Enum.map(&%{"family" => &1["family"], "field" => "metric_judge"})
  end

  defp papillon_judge_present?(row) do
    judge = row["metric_judge"]

    is_map(judge) and judge["kind"] == "papillon_quality_leakage" and
      concrete_source?(judge["model"]) and concrete_source?(judge["quality_judge"]) and
      concrete_source?(judge["leakage_judge"])
  end

  defp distinct_split_digests?(gap) do
    digests = gap["split_digests"]

    is_map(digests) and
      Enum.all?(["train", "dev", "test"], &concrete_source?(digests[&1])) and
      digests["train"] != digests["dev"] and digests["train"] != digests["test"] and
      digests["dev"] != digests["test"]
  end

  defp full_split_counts?(counts) when is_map(counts) do
    Enum.all?(["train", "dev", "test"], fn split ->
      positive_integer?(counts[split]) and counts[split] > 1
    end)
  end

  defp full_split_counts?(_counts), do: false

  defp honest_seed_selection?(selection) when is_map(selection) do
    method = selection["method"]
    seeds = selection["seeds"]
    selected_seed = selection["selected_seed"]

    is_list(seeds) and seeds != [] and length(Enum.uniq(seeds)) == length(seeds) and
      Enum.all?(seeds, &is_integer/1) and selection["test_scores_used"] == false and
      concrete_source?(selection["source"]) and
      case method do
        "predeclared" -> selected_seed in seeds and is_nil(selection["selection_split"])
        "best_dev" -> selected_seed in seeds and selection["selection_split"] == "dev"
        "aggregate" -> is_nil(selected_seed) and is_nil(selection["selection_split"])
        _ -> false
      end
  end

  defp honest_seed_selection?(_selection), do: false

  defp numeric?(value), do: is_integer(value) or is_float(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp concrete_source?(value) when is_binary(value) do
    value = String.trim(value)
    downcased = String.downcase(value)

    value != "" and
      downcased not in ["unknown", "unavailable", "pending", "todo", "tbd", "n/a"] and
      not String.contains?(downcased, "smoke") and
      not String.contains?(downcased, "placeholder") and
      not String.contains?(downcased, "not run") and
      not String.contains?(downcased, "deterministic")
  end

  defp concrete_source?(_value), do: false
end
