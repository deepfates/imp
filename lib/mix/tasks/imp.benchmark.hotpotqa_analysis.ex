defmodule Mix.Tasks.Imp.Benchmark.HotpotqaAnalysis do
  @moduledoc """
  Analyze HotPotQA disagreements in Imp-vs-DSPy parity artifacts.

      mix imp.benchmark.hotpotqa_analysis \\
        --campaign-id req-llm-current-low-cost-full-YYYYMMDD \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl

  The analysis is row-based: each absolute HotPotQA index is counted once and
  the newest matching parity artifact wins. It is diagnostic evidence only; it
  does not change strict exact-match campaign scoring.
  """

  use Mix.Task

  @shortdoc "Classify HotPotQA parity disagreements"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          in: :string,
          out: :string,
          campaign_id: :string,
          hotpotqa: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input_glob = Keyword.get(opts, :in, "benchmarks/results/imp-dspy-parity-*.json")
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    campaign_id = Keyword.get(opts, :campaign_id) || Mix.raise("--campaign-id is required")
    hotpotqa_path = Keyword.get(opts, :hotpotqa) || Mix.raise("--hotpotqa is required")

    File.mkdir_p!(out_dir)

    rows =
      input_paths(input_glob, argv)
      |> Enum.map(&load_report/1)
      |> filter_campaign_id(campaign_id)
      |> hotpotqa_rows()

    if rows == %{}, do: Mix.raise("no HotPotQA rows matched #{input_glob}")

    gold_by_index = load_gold(hotpotqa_path)
    validate_gold_coverage!(rows, gold_by_index, hotpotqa_path)
    report = report(rows, gold_by_index, campaign_id, hotpotqa_path)

    out_path =
      Path.join(out_dir, "hotpotqa-disagreement-analysis-#{timestamp_slug()}.json")

    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("HotPotQA disagreement analysis: #{out_path}")
    Mix.shell().info("covered rows: #{report["coverage"]["covered"]}")
    Mix.shell().info("pass disagreements: #{report["summary"]["pass_disagreements"]}")
  end

  defp input_paths(input_glob, argv) do
    [input_glob | argv]
    |> Enum.flat_map(&expand_input/1)
    |> Enum.uniq()
  end

  defp expand_input(path) do
    if File.dir?(path) do
      path |> Path.join("imp-dspy-parity-*.json") |> Path.wildcard()
    else
      Path.wildcard(path)
    end
  end

  defp load_report(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("__path__", path)
  end

  defp filter_campaign_id(reports, nil), do: reports

  defp filter_campaign_id(reports, campaign_id),
    do: Enum.filter(reports, &(&1["campaign_id"] == campaign_id))

  defp hotpotqa_rows(reports) do
    Enum.reduce(reports, %{}, fn report, acc ->
      generated_at = report["generated_at"] || ""

      report
      |> Map.get("tasks", [])
      |> Enum.filter(&(&1["task"] == "hotpotqa"))
      |> Enum.reduce(acc, fn task, task_acc ->
        offset = task["offset"] || 0
        imp_error_indexes = task_error_indexes(task["imp_errors"] || [])
        dspy_error_indexes = task_error_indexes(task["dspy_errors"] || [])

        task
        |> Map.get("row_agreement", [])
        |> Enum.reduce(task_acc, fn row, row_acc ->
          absolute_index = row["absolute_index"] || offset + row["index"]
          imp_error? = task_error_at?(imp_error_indexes, row, "imp")
          dspy_error? = task_error_at?(dspy_error_indexes, row, "dspy")

          record =
            row
            |> Map.take([
              "absolute_index",
              "index",
              "imp_passed",
              "dspy_passed",
              "pass_agreement",
              "answer_agreement",
              "imp_answer",
              "dspy_answer",
              "imp_metric_metadata",
              "dspy_metric_metadata"
            ])
            |> Map.merge(%{
              "absolute_index" => absolute_index,
              "source_report" => report["__path__"],
              "source_generated_at" => generated_at
            })

          if imp_error? or dspy_error? do
            row_acc
          else
            Map.update(row_acc, absolute_index, record, fn old ->
              if generated_at >= old["source_generated_at"], do: record, else: old
            end)
          end
        end)
      end)
    end)
  end

  defp task_error_indexes(errors) when is_list(errors) do
    errors
    |> Enum.map(& &1["index"])
    |> Enum.filter(&is_integer/1)
    |> MapSet.new()
  end

  defp task_error_indexes(errors) when is_integer(errors) and errors > 0, do: :answerless
  defp task_error_indexes(_errors), do: MapSet.new()

  defp task_error_at?(:answerless, row, runtime), do: is_nil(row["#{runtime}_answer"])

  defp task_error_at?(%MapSet{} = indexes, row, _runtime),
    do: MapSet.member?(indexes, row["index"])

  defp load_gold(path) do
    path
    |> File.stream!()
    |> Stream.reject(&(String.trim(&1) == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Enum.with_index()
    |> Map.new(fn {row, index} ->
      {index,
       %{
         "answer" => row["answer"],
         "question" => row["question"]
       }}
    end)
  end

  defp validate_gold_coverage!(rows_by_index, gold_by_index, hotpotqa_path) do
    missing =
      rows_by_index
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(gold_by_index, &1))
      |> Enum.take(10)

    if missing != [] do
      Mix.raise(
        "--hotpotqa must be the full validation file indexed from zero; " <>
          "#{hotpotqa_path} is missing absolute indices #{inspect(missing)}"
      )
    end
  end

  defp report(rows_by_index, gold_by_index, campaign_id, hotpotqa_path) do
    rows =
      rows_by_index
      |> Enum.sort_by(fn {index, _row} -> index end)
      |> Enum.map(fn {index, row} -> classify_row(row, gold_by_index[index]) end)

    disagreements =
      Enum.reject(rows, fn row ->
        row["pass_agreement"] == true and row["answer_agreement"] == true
      end)

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "campaign_id" => campaign_id,
      "hotpotqa_path" => hotpotqa_path,
      "coverage" => %{"covered" => length(rows), "disagreements" => length(disagreements)},
      "summary" => summary(rows, disagreements),
      "categories" => category_counts(disagreements),
      "directions" => direction_counts(disagreements),
      "answer_types" => answer_type_counts(disagreements),
      "examples" => examples(disagreements)
    }
  end

  defp classify_row(row, gold) do
    gold_answer = gold && gold["answer"]
    imp_answer = row["imp_answer"]
    dspy_answer = row["dspy_answer"]

    Map.merge(row, %{
      "gold_answer" => gold_answer,
      "question" => gold && gold["question"],
      "direction" => direction(row),
      "answer_type" => answer_type(gold_answer),
      "category" => category(row, gold_answer, imp_answer, dspy_answer),
      "f1_delta" => f1_delta(row)
    })
  end

  defp summary(rows, disagreements) do
    pass_disagreements = Enum.count(rows, &(&1["pass_agreement"] == false))
    answer_disagreements = Enum.count(rows, &(&1["answer_agreement"] == false))
    imp_passes = Enum.count(rows, &(&1["imp_passed"] == true))
    dspy_passes = Enum.count(rows, &(&1["dspy_passed"] == true))

    %{
      "rows" => length(rows),
      "disagreements" => length(disagreements),
      "pass_disagreements" => pass_disagreements,
      "answer_disagreements" => answer_disagreements,
      "imp_passes" => imp_passes,
      "dspy_passes" => dspy_passes,
      "score_delta" => safe_div(imp_passes - dspy_passes, length(rows)),
      "mean_f1_delta" => rows |> Enum.map(& &1["f1_delta"]) |> Enum.filter(&is_number/1) |> mean()
    }
  end

  defp direction(%{"imp_passed" => true, "dspy_passed" => false}), do: "imp_only_pass"
  defp direction(%{"imp_passed" => false, "dspy_passed" => true}), do: "dspy_only_pass"
  defp direction(%{"imp_passed" => true, "dspy_passed" => true}), do: "both_pass"
  defp direction(%{"imp_passed" => false, "dspy_passed" => false}), do: "both_fail"
  defp direction(%{"imp_passed" => true, "dspy_passed" => nil}), do: "imp_only_missing_dspy"
  defp direction(%{"imp_passed" => nil, "dspy_passed" => true}), do: "dspy_only_missing_imp"
  defp direction(%{"imp_passed" => false, "dspy_passed" => nil}), do: "imp_fail_missing_dspy"
  defp direction(%{"imp_passed" => nil, "dspy_passed" => false}), do: "dspy_fail_missing_imp"
  defp direction(_row), do: "missing_or_invalid_counterpart"

  defp category(_row, nil, _imp, _dspy), do: "missing_gold"

  defp category(row, gold, imp, dspy) do
    gold_norm = Imp.Metrics.normalize_text(gold)
    imp_norm = Imp.Metrics.normalize_text(imp)
    dspy_norm = Imp.Metrics.normalize_text(dspy)

    cond do
      row["pass_agreement"] == true and row["answer_agreement"] == true ->
        "agreement"

      yes_no_gold?(gold) and row["imp_passed"] == false and row["dspy_passed"] == true and
        dspy_norm == gold_norm and nonboolean_explanation?(imp_norm) ->
        "imp_yes_no_explanation"

      yes_no_gold?(gold) and row["imp_passed"] == false and row["dspy_passed"] == true and
        dspy_norm == gold_norm and imp_norm not in ["yes", "no"] ->
        "imp_wrong_nonboolean_yes_no"

      yes_no_gold?(gold) and row["imp_passed"] == true and row["dspy_passed"] == false and
        imp_norm == gold_norm and nonboolean_explanation?(dspy_norm) ->
        "dspy_yes_no_explanation"

      yes_no_gold?(gold) and row["imp_passed"] == true and row["dspy_passed"] == false and
        imp_norm == gold_norm and dspy_norm not in ["yes", "no"] ->
        "dspy_wrong_nonboolean_yes_no"

      row["imp_passed"] == false and row["dspy_passed"] == true and
          contains_token_sequence?(imp_norm, gold_norm) ->
        "imp_overlong_span"

      row["imp_passed"] == false and row["dspy_passed"] == true and
          contains_token_sequence?(gold_norm, imp_norm) ->
        "imp_short_span"

      row["imp_passed"] == true and row["dspy_passed"] == false and
          contains_token_sequence?(dspy_norm, gold_norm) ->
        "dspy_overlong_span"

      row["imp_passed"] == true and row["dspy_passed"] == false and
          contains_token_sequence?(gold_norm, dspy_norm) ->
        "dspy_short_span"

      imp_norm == dspy_norm ->
        "shared_wrong_answer"

      true ->
        "different_wrong_or_ambiguous"
    end
  end

  defp answer_type(answer) do
    norm = Imp.Metrics.normalize_text(answer)

    cond do
      norm in ["yes", "no"] -> "yes_no"
      String.match?(norm, ~r/^\d+(?:\s+\d+)*$/) -> "numeric"
      String.length(norm) <= 20 -> "short_span"
      true -> "long_span"
    end
  end

  defp yes_no_gold?(answer), do: answer_type(answer) == "yes_no"

  defp nonboolean_explanation?(answer) do
    answer not in ["", "yes", "no"] and length(String.split(answer)) > 1
  end

  defp contains_token_sequence?(_left, ""), do: false
  defp contains_token_sequence?("", _right), do: false

  defp contains_token_sequence?(left, right) do
    left_tokens = String.split(left)
    right_tokens = String.split(right)
    right_tokens != [] and subsequence?(left_tokens, right_tokens)
  end

  defp subsequence?(tokens, sequence) when length(sequence) > length(tokens), do: false

  defp subsequence?(tokens, sequence) do
    0..(length(tokens) - length(sequence))
    |> Enum.any?(fn index -> Enum.slice(tokens, index, length(sequence)) == sequence end)
  end

  defp category_counts(rows), do: counts(rows, "category")
  defp direction_counts(rows), do: counts(rows, "direction")
  defp answer_type_counts(rows), do: counts(rows, "answer_type")

  defp counts(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_key, count} -> -count end)
    |> Map.new()
  end

  defp examples(disagreements) do
    disagreements
    |> Enum.take(50)
    |> Enum.map(fn row ->
      Map.take(row, [
        "absolute_index",
        "direction",
        "category",
        "answer_type",
        "gold_answer",
        "imp_answer",
        "dspy_answer",
        "f1_delta",
        "question",
        "source_report"
      ])
    end)
  end

  defp f1_delta(row) do
    imp = metric(row, "imp_metric_metadata", "official_hotpotqa_f1")
    dspy = metric(row, "dspy_metric_metadata", "official_hotpotqa_f1")

    if is_number(imp) and is_number(dspy), do: imp - dspy
  end

  defp metric(row, metadata_key, metric_key) do
    case get_in(row, [metadata_key, metric_key]) do
      value when is_number(value) -> value
      _other -> nil
    end
  end

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
