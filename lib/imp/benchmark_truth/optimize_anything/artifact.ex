defmodule Imp.BenchmarkTruth.OptimizeAnything.Artifact do
  @moduledoc false

  @schema_version 1
  @artifact_classes ["code_artifact", "agent_config", "scheduling_heuristic"]
  @invalid_claim_markers ["placeholder", "forged", "fabricated", "fake", "not run"]
  @non_live_markers ["smoke", "deterministic", "demo", "example only"]
  @digest_regex ~r/\A(?:sha256:)?[0-9a-f]{64}\z/
  @relative_tolerance 1.0e-9

  @required_fields [
    "artifact_class",
    "evaluator_id",
    "baseline",
    "optimized",
    "comparator",
    "absolute_lift",
    "relative_lift",
    "metric_calls",
    "input_tokens",
    "output_tokens",
    "provider",
    "model",
    "cost_usd",
    "wall_time_ms",
    "seed",
    "train_count",
    "val_count",
    "train_digest",
    "val_digest",
    "provenance",
    "status",
    "effectiveness_authorized",
    "reproducibility"
  ]

  @doc "Returns the evidence schema version."
  def schema_version, do: @schema_version

  @doc "Returns the artifact classes required for a complete campaign."
  def artifact_classes, do: @artifact_classes

  @doc "Validates campaign rows and returns machine-readable defects."
  def validate_rows(rows, opts \\ [])

  def validate_rows(rows, opts) when is_list(rows) do
    mode = Keyword.get(opts, :mode, :full)

    unless mode in [:full, :smoke] do
      raise ArgumentError, "mode must be :full or :smoke"
    end

    classes = Enum.map(rows, &map_value(&1, "artifact_class"))

    duplicate_classes =
      classes
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_class, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    invalid_rows =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, index} -> validate_row(row, mode, index) end)

    missing_classes = @artifact_classes -- Enum.uniq(classes)
    unknown_classes = Enum.uniq(classes) -- @artifact_classes

    passing =
      invalid_rows == [] and missing_classes == [] and unknown_classes == [] and
        duplicate_classes == [] and length(rows) == length(@artifact_classes)

    %{
      passing: passing,
      authorizes_effectiveness: passing and mode == :full,
      mode: mode,
      missing_classes: missing_classes,
      unknown_classes: unknown_classes,
      duplicate_classes: duplicate_classes,
      invalid_rows: invalid_rows
    }
  end

  def validate_rows(_rows, _opts) do
    %{
      passing: false,
      authorizes_effectiveness: false,
      mode: :invalid,
      missing_classes: @artifact_classes,
      unknown_classes: [],
      duplicate_classes: [],
      invalid_rows: [%{"index" => nil, "field" => "rows", "reason" => "must be a list"}]
    }
  end

  @doc "Builds a schema-versioned evidence artifact from validated or rejected rows."
  def build(rows, opts \\ []) do
    mode = Keyword.get(opts, :mode, :full)
    validation = validate_rows(rows, mode: mode)

    %{
      "schema_version" => @schema_version,
      "runner" => "imp-optimize-anything-replication",
      "generated_at" =>
        Keyword.get_lazy(opts, :generated_at, fn ->
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        end),
      "git_sha" => Keyword.get(opts, :git_sha, "unknown"),
      "source" => Keyword.get(opts, :source),
      "summary" => %{
        "all_passing" => validation.passing,
        "effectiveness_authorized" => validation.authorizes_effectiveness,
        "evidence_level" => if(mode == :full, do: "full", else: "smoke"),
        "missing_classes" => validation.missing_classes,
        "unknown_classes" => validation.unknown_classes,
        "duplicate_classes" => validation.duplicate_classes,
        "invalid_rows" => validation.invalid_rows
      },
      "rows" => rows
    }
  end

  @doc "Returns true only for a complete, live artifact that authorizes effectiveness."
  def full_artifact?(artifact) when is_map(artifact) do
    rows = map_value(artifact, "rows")
    validation = validate_rows(rows, mode: :full)

    map_value(artifact, "schema_version") == @schema_version and
      map_value(artifact, "runner") == "imp-optimize-anything-replication" and
      get_value(artifact, ["summary", "all_passing"]) == true and
      get_value(artifact, ["summary", "effectiveness_authorized"]) == true and
      get_value(artifact, ["summary", "evidence_level"]) == "full" and
      validation.authorizes_effectiveness
  end

  def full_artifact?(_artifact), do: false

  defp validate_row(row, mode, index) when is_map(row) do
    missing =
      @required_fields
      |> Enum.reject(&Map.has_key?(row, &1))
      |> Enum.map(&defect(index, &1, "is required"))

    checks = [
      valid_class?(row),
      concrete_string?(row["evaluator_id"], mode),
      scored_artifact?(row["baseline"], mode),
      scored_artifact?(row["optimized"], mode),
      comparator?(row["comparator"], mode),
      finite_number?(row["absolute_lift"]),
      finite_number?(row["relative_lift"]),
      lift_matches?(row),
      effectiveness_lift?(row, mode),
      counter?(row["metric_calls"], mode),
      usage_count?(row["input_tokens"], mode),
      usage_count?(row["output_tokens"], mode),
      concrete_string?(row["provider"], mode),
      concrete_string?(row["model"], mode),
      cost?(row["cost_usd"], mode),
      duration?(row["wall_time_ms"], mode),
      is_integer(row["seed"]),
      positive_integer?(row["train_count"]),
      positive_integer?(row["val_count"]),
      digest?(row["train_digest"]),
      digest?(row["val_digest"]),
      distinct_digests?(row),
      provenance?(row["provenance"], mode),
      status?(row, mode),
      reproducibility?(row["reproducibility"], mode),
      no_invalid_claims?(row)
    ]

    fields = [
      "artifact_class",
      "evaluator_id",
      "baseline",
      "optimized",
      "comparator",
      "absolute_lift",
      "relative_lift",
      "lift",
      "effectiveness_lift",
      "metric_calls",
      "input_tokens",
      "output_tokens",
      "provider",
      "model",
      "cost_usd",
      "wall_time_ms",
      "seed",
      "train_count",
      "val_count",
      "train_digest",
      "val_digest",
      "split_digests",
      "provenance",
      "status",
      "reproducibility",
      "claims"
    ]

    invalid =
      checks
      |> Enum.zip(fields)
      |> Enum.reject(&elem(&1, 0))
      |> Enum.map(fn {_valid, field} -> defect(index, field, reason(field, mode)) end)

    Enum.uniq(missing ++ invalid)
  end

  defp validate_row(_row, _mode, index), do: [defect(index, "row", "must be a map")]

  defp valid_class?(row), do: row["artifact_class"] in @artifact_classes

  defp scored_artifact?(value, mode) when is_map(value) do
    concrete_string?(value["artifact"], mode) and finite_number?(value["score"])
  end

  defp scored_artifact?(_value, _mode), do: false
  defp comparator?(nil, _mode), do: true
  defp comparator?(value, mode), do: scored_artifact?(value, mode)

  defp lift_matches?(%{"baseline" => baseline, "optimized" => optimized} = row)
       when is_map(baseline) and is_map(optimized) do
    with baseline_score when is_number(baseline_score) <- baseline["score"],
         optimized_score when is_number(optimized_score) <- optimized["score"],
         absolute when is_number(absolute) <- row["absolute_lift"],
         relative when is_number(relative) <- row["relative_lift"],
         true <- finite_number?(baseline_score) and baseline_score != 0,
         true <- Enum.all?([optimized_score, absolute, relative], &finite_number?/1) do
      close?(absolute, optimized_score - baseline_score) and
        close?(relative, (optimized_score - baseline_score) / abs(baseline_score))
    else
      _ -> false
    end
  end

  defp lift_matches?(_row), do: false

  defp effectiveness_lift?(_row, :smoke), do: true

  defp effectiveness_lift?(row, :full) do
    baseline_score = get_value(row, ["baseline", "score"])
    optimized_score = get_value(row, ["optimized", "score"])

    Enum.all?(
      [baseline_score, optimized_score, row["absolute_lift"], row["relative_lift"]],
      &finite_number?/1
    ) and optimized_score > baseline_score and row["absolute_lift"] > 0 and
      row["relative_lift"] > 0
  end

  defp provenance?(value, mode) when is_map(value) do
    concrete_string?(value["run_id"], mode) and
      concrete_string?(value["checkpoint"], mode) and
      concrete_string?(value["git_sha"], mode)
  end

  defp provenance?(_value, _mode), do: false

  defp reproducibility?(value, :smoke) when is_map(value) do
    Enum.all?(["command", "evaluator_version", "dataset_source", "environment"], fn field ->
      concrete_string?(value[field], :smoke)
    end) and is_map(value["source_commits"]) and map_size(value["source_commits"]) > 0 and
      Enum.all?(value["source_commits"], fn {name, sha} ->
        concrete_string?(to_string(name), :smoke) and concrete_string?(sha, :smoke)
      end)
  end

  defp reproducibility?(value, :full) when is_map(value) do
    runs = value["runs"]

    Enum.all?(["command", "evaluator_version", "dataset_source", "environment"], fn field ->
      concrete_string?(value[field], :full)
    end) and valid_source_commits?(value["source_commits"]) and reproducible_runs?(runs)
  end

  defp reproducibility?(_value, _mode), do: false

  defp valid_source_commits?(commits) when is_map(commits) and map_size(commits) > 0 do
    Enum.all?(commits, fn {name, sha} ->
      concrete_string?(to_string(name), :full) and concrete_string?(sha, :full)
    end)
  end

  defp valid_source_commits?(_commits), do: false

  defp reproducible_runs?(runs) when is_list(runs) and length(runs) >= 3 do
    seeds = Enum.map(runs, &map_value(&1, "seed"))
    lifts = Enum.map(runs, &map_value(&1, "lift"))

    length(Enum.uniq(seeds)) == length(seeds) and Enum.all?(runs, &reproducible_run?/1) and
      Enum.count(lifts, &(&1 > 0)) > div(length(lifts), 2) and Enum.sum(lifts) / length(lifts) > 0
  end

  defp reproducible_runs?(_runs), do: false

  defp reproducible_run?(run) when is_map(run) do
    is_integer(run["seed"]) and finite_number?(run["optimized_score"]) and
      finite_number?(run["lift"]) and digest?(run["artifact_digest"]) and
      concrete_string?(run["run_id"], :full) and concrete_string?(run["checkpoint"], :full)
  end

  defp reproducible_run?(_run), do: false

  defp status?(row, :smoke) do
    row["status"] == "smoke" and row["effectiveness_authorized"] == false
  end

  defp status?(row, :full) do
    row["status"] == "live" and row["effectiveness_authorized"] == true
  end

  defp no_invalid_claims?(row) do
    row
    |> text_values()
    |> Enum.all?(fn value ->
      downcased = String.downcase(value)
      Enum.all?(@invalid_claim_markers, &(not String.contains?(downcased, &1)))
    end)
  end

  defp concrete_string?(value, mode) when is_binary(value) do
    value = String.trim(value)
    downcased = String.downcase(value)

    value != "" and
      Enum.all?(@invalid_claim_markers, &(not String.contains?(downcased, &1))) and
      (mode == :smoke or Enum.all?(@non_live_markers, &(not String.contains?(downcased, &1))))
  end

  defp concrete_string?(_value, _mode), do: false

  defp text_values(value) when is_binary(value), do: [value]
  defp text_values(value) when is_list(value), do: Enum.flat_map(value, &text_values/1)

  defp text_values(value) when is_map(value) do
    Enum.flat_map(value, fn {key, item} -> text_values(key) ++ text_values(item) end)
  end

  defp text_values(_value), do: []

  defp digest?(value) when is_binary(value), do: Regex.match?(@digest_regex, value)
  defp digest?(_value), do: false

  defp distinct_digests?(row) do
    digest?(row["train_digest"]) and digest?(row["val_digest"]) and
      row["train_digest"] != row["val_digest"]
  end

  defp counter?(value, :full), do: positive_integer?(value)
  defp counter?(value, :smoke), do: nonnegative_integer?(value)
  defp usage_count?(value, :full), do: positive_integer?(value)
  defp usage_count?(value, :smoke), do: nonnegative_integer?(value)
  defp cost?(value, :full), do: finite_number?(value) and value > 0
  defp cost?(value, :smoke), do: nonnegative_number?(value)
  defp duration?(value, :full), do: positive_integer?(value)
  defp duration?(value, :smoke), do: nonnegative_integer?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0
  defp nonnegative_number?(value), do: finite_number?(value) and value >= 0

  defp finite_number?(value) when is_integer(value), do: true

  defp finite_number?(value) when is_float(value) do
    value
    |> :erlang.float_to_binary([:compact])
    |> then(&(&1 not in ["nan", "inf", "-inf"]))
  end

  defp finite_number?(_value), do: false

  defp close?(left, right) do
    abs(left - right) <= @relative_tolerance * max(1.0, max(abs(left), abs(right)))
  end

  defp defect(index, field, reason),
    do: %{"index" => index, "field" => field, "reason" => reason}

  defp reason("status", :smoke), do: "smoke rows must be non-authorizing"
  defp reason("status", :full), do: "full rows must be live and effectiveness-authorized"
  defp reason("lift", _mode), do: "must match the baseline and optimized scores"
  defp reason("effectiveness_lift", _mode), do: "optimized evidence must show positive lift"
  defp reason("split_digests", _mode), do: "train and validation digests must be distinct"
  defp reason("claims", _mode), do: "contains a placeholder or forged-evidence marker"
  defp reason(_field, _mode), do: "has an invalid or non-finite value"

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)

  defp map_value(_value, _key), do: nil

  defp get_value(map, [key]), do: map_value(map, key)

  defp get_value(map, [key | rest]) do
    map |> map_value(key) |> get_value(rest)
  end
end
