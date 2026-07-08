defmodule Mix.Tasks.Dsex.Benchmark.Parity.Aggregate do
  @moduledoc """
  Aggregate DSEx-vs-DSPy parity chunk artifacts into one campaign report.

      mix dsex.benchmark.parity.aggregate --provider req_llm --model "$DSEX_PARITY_MODEL"

  The aggregator is row-based: each `(task, absolute_index)` is counted once,
  and the newest artifact wins when chunks overlap. This prevents smoke runs
  from inflating coverage or score totals. Aggregates are scoped by DSEx
  provider and model so historical client paths cannot be mixed into ReqLLM
  campaigns.
  """

  use Mix.Task

  @shortdoc "Aggregate DSEx-vs-DSPy parity chunk reports"
  @full_lengths %{"gsm8k" => 1319, "hotpotqa" => 7405}
  @max_disagreement_examples 20
  @max_sample_chars 500
  @evidence_policy_version 2

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          in: :string,
          out: :string,
          provider: :string,
          model: :string,
          campaign_id: :string,
          max_concurrency: :integer,
          strict_task_gap: :float,
          strict_aggregate_gap: :float,
          max_latency_ratio: :float
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    input_glob = Keyword.get(opts, :in, "benchmarks/results/dsex-dspy-parity-*.json")
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    File.mkdir_p!(out_dir)

    reports =
      input_glob
      |> Path.wildcard()
      |> Enum.map(&load_report/1)
      |> filter_model(Keyword.get(opts, :model))
      |> filter_provider(Keyword.get(opts, :provider))
      |> filter_campaign_id(Keyword.get(opts, :campaign_id))
      |> filter_max_concurrency(Keyword.get(opts, :max_concurrency))
      |> require_generation!()

    if reports == [] do
      Mix.raise("no parity reports matched #{input_glob}")
    end

    campaign_id = Keyword.get(opts, :campaign_id)

    aggregate =
      aggregate_reports(reports,
        campaign_id: campaign_id,
        strict_task_gap: Keyword.get(opts, :strict_task_gap, 0.01),
        strict_aggregate_gap: Keyword.get(opts, :strict_aggregate_gap, 0.01),
        max_latency_ratio: Keyword.get(opts, :max_latency_ratio, 1.5)
      )

    out_path =
      Path.join(
        out_dir,
        "dsex-dspy-parity-campaign-#{model_slug(aggregate["provider"])}-#{model_slug(aggregate["model"])}-#{timestamp_slug()}.json"
      )

    File.write!(out_path, Jason.encode!(aggregate, pretty: true) <> "\n")

    Mix.shell().info("parity campaign report: #{out_path}")

    Mix.shell().info(
      "coverage: #{aggregate["coverage"]["covered"]}/#{aggregate["coverage"]["expected"]}"
    )

    Mix.shell().info("full parity: #{aggregate["parity"]["full_parity"]}")
  end

  defp load_report(path) do
    report = path |> File.read!() |> Jason.decode!()
    Map.put(report, "__path__", path)
  end

  defp filter_model(reports, nil), do: reports

  defp filter_model(reports, model) do
    Enum.filter(reports, &(report_model(&1) == model))
  end

  defp filter_provider(reports, nil), do: reports

  defp filter_provider(reports, provider) do
    Enum.filter(reports, &(report_provider(&1) == provider))
  end

  defp filter_campaign_id(reports, nil), do: reports

  defp filter_campaign_id(reports, campaign_id) do
    Enum.filter(reports, &(&1["campaign_id"] == campaign_id))
  end

  defp filter_max_concurrency(reports, nil), do: reports

  defp filter_max_concurrency(_reports, max_concurrency)
       when not is_integer(max_concurrency) or max_concurrency <= 0 do
    Mix.raise("--max-concurrency must be a positive integer, got: #{inspect(max_concurrency)}")
  end

  defp filter_max_concurrency(reports, max_concurrency) do
    Enum.filter(reports, &(report_max_concurrency(&1) == max_concurrency))
  end

  defp require_generation!(reports) do
    reports = Enum.filter(reports, &is_map(&1["generation"]))

    if reports == [] do
      Mix.raise(
        "no parity reports with recorded generation settings matched; rerun live chunks with the current parity runner"
      )
    end

    generation =
      reports
      |> Enum.map(&canonical_generation(&1["generation"]))
      |> Enum.uniq()
      |> one_generation!()

    Enum.map(reports, &Map.put(&1, "__canonical_generation__", generation))
  end

  defp aggregate_reports(reports, opts) do
    identity = reports |> Enum.map(&report_identity/1) |> Enum.uniq() |> one_identity!()
    provider = identity["provider"]
    model = identity["model"]
    rows_by_task = rows_by_task(reports)

    task_reports =
      Enum.map(@full_lengths, fn {task, expected} ->
        task_summary(task, expected, rows_by_task[task] || %{})
      end)

    covered = Enum.sum(Enum.map(task_reports, & &1["coverage"]["covered"]))
    expected = Enum.sum(Enum.map(task_reports, & &1["coverage"]["expected"]))
    dsex_passes = Enum.sum(Enum.map(task_reports, & &1["dsex_passes"]))
    dspy_passes = Enum.sum(Enum.map(task_reports, & &1["dspy_passes"]))
    dsex_score = safe_div(dsex_passes, covered)
    dspy_score = safe_div(dspy_passes, covered)
    score_delta = dsex_score - dspy_score
    max_task_gap = task_reports |> Enum.map(&abs(&1["score_delta"])) |> Enum.max(fn -> 0.0 end)
    aggregate_gap = abs(score_delta)
    strict_task_gap = Keyword.fetch!(opts, :strict_task_gap)
    strict_aggregate_gap = Keyword.fetch!(opts, :strict_aggregate_gap)
    max_latency_ratio = Keyword.fetch!(opts, :max_latency_ratio)
    campaign_id = Keyword.get(opts, :campaign_id)
    full_coverage? = Enum.all?(task_reports, &get_in(&1, ["coverage", "full"]))
    generation = generation_summary(reports)
    effective_generation = generation["effective"] || %{}
    execution = execution_summary(reports)

    latency_ratio =
      ratio(
        Enum.sum(Enum.map(task_reports, & &1["dsex_duration_ms"])),
        Enum.sum(Enum.map(task_reports, & &1["dspy_duration_ms"]))
      )

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "campaign_id" => campaign_id,
      "provider" => provider,
      "model" => model,
      "evidence_policy" => evidence_policy(),
      "source_reports" => source_reports(reports),
      "generation" => generation,
      "execution" => execution,
      "runner_order" => runner_order_summary(reports),
      "coverage" => %{
        "covered" => covered,
        "expected" => expected,
        "full" => full_coverage?
      },
      "aggregate" => %{
        "dsex_score" => dsex_score,
        "dspy_score" => dspy_score,
        "score_delta" => score_delta,
        "dsex_duration_ms" => Enum.sum(Enum.map(task_reports, & &1["dsex_duration_ms"])),
        "dspy_duration_ms" => Enum.sum(Enum.map(task_reports, & &1["dspy_duration_ms"])),
        "latency_ratio_dsex_over_dspy" => latency_ratio
      },
      "tasks" => task_reports,
      "next_chunks" => next_chunks(task_reports),
      "parity" => %{
        "full_parity" =>
          full_coverage? and generation["consistent"] == true and
            execution["max_concurrency_consistent"] == true and
            effective_generation["complete"] == true and effective_generation["matched"] == true and
            effective_generation["wire_api_matched"] == true and
            within?(aggregate_gap, strict_aggregate_gap) and
            within?(max_task_gap, strict_task_gap) and
            latency_within?(latency_ratio, max_latency_ratio),
        "full_coverage" => full_coverage?,
        "latency_parity" => latency_within?(latency_ratio, max_latency_ratio),
        "max_concurrency_consistent" => execution["max_concurrency_consistent"],
        "aggregate_gap" => aggregate_gap,
        "max_task_score_gap" => max_task_gap,
        "max_latency_ratio_dsex_over_dspy" => max_latency_ratio,
        "strict_aggregate_gap" => strict_aggregate_gap,
        "strict_task_gap" => strict_task_gap,
        "note" =>
          parity_note(
            full_coverage?,
            aggregate_gap,
            max_task_gap,
            strict_aggregate_gap,
            strict_task_gap,
            latency_ratio,
            max_latency_ratio,
            execution["max_concurrency_consistent"]
          )
      }
    }
  end

  defp evidence_policy do
    %{
      "version" => @evidence_policy_version,
      "runner_error_rows" => "incomplete",
      "answerless_unindexed_runner_errors" => "incomplete",
      "newer_incomplete_overwrites_complete" => false,
      "coverage_unit" => "accepted_complete_row"
    }
  end

  defp rows_by_task(reports) do
    Enum.reduce(reports, %{}, fn report, acc ->
      Enum.reduce(report["tasks"] || [], acc, fn task, task_acc ->
        task_name = task["task"]
        offset = task["offset"] || 0
        generated_at = report["generated_at"] || ""
        dsex_error_indexes = task_error_indexes(task["dsex_errors"] || [])
        dspy_error_indexes = task_error_indexes(task["dspy_errors"] || [])

        task_rows =
          task
          |> Map.get("row_agreement", [])
          |> Enum.map(fn row ->
            absolute_index = row["absolute_index"] || offset + row["index"]

            {absolute_index,
             row_record(report, task, row, absolute_index, generated_at,
               dsex_error?: task_error_at?(dsex_error_indexes, row, "dsex"),
               dspy_error?: task_error_at?(dspy_error_indexes, row, "dspy")
             )}
          end)

        Map.update(task_acc, task_name, Map.new(task_rows), fn existing ->
          Enum.reduce(task_rows, existing, fn {index, row}, rows ->
            Map.update(rows, index, row, fn old -> newest(old, row) end)
          end)
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

  defp row_record(report, task, row, absolute_index, generated_at, opts) do
    dsex_error? = Keyword.fetch!(opts, :dsex_error?)
    dspy_error? = Keyword.fetch!(opts, :dspy_error?)

    row_evidence_complete? =
      row["row_evidence_complete"] != false and not dsex_error? and not dspy_error?

    %{
      "absolute_index" => absolute_index,
      "index" => row["index"],
      "dsex_row_present" => row["dsex_row_present"] != false,
      "dspy_row_present" => row["dspy_row_present"] != false,
      "row_evidence_complete" => row_evidence_complete?,
      "dsex_runner_error" => dsex_error?,
      "dspy_runner_error" => dspy_error?,
      "dsex_passed" => row["dsex_passed"] == true,
      "dspy_passed" => row["dspy_passed"] == true,
      "pass_agreement" => row["pass_agreement"] == true,
      "answer_agreement" => row["answer_agreement"] == true,
      "dsex_answer" => row["dsex_answer"],
      "dspy_answer" => row["dspy_answer"],
      "dsex_duration_ms" => row["dsex_duration_ms"],
      "dspy_duration_ms" => row["dspy_duration_ms"],
      "dsex_instrumentation" => row["dsex_instrumentation"] || %{},
      "dspy_instrumentation" => row["dspy_instrumentation"] || %{},
      "dsex_metric_metadata" => row["dsex_metric_metadata"] || %{},
      "dspy_metric_metadata" => row["dspy_metric_metadata"] || %{},
      "diagnostic" => row["diagnostic"] || %{},
      "source_report" => report["__path__"],
      "source_generated_at" => generated_at,
      "task_duration" => %{
        "dsex_duration_ms" => task["dsex_duration_ms"] || 0.0,
        "dspy_duration_ms" => task["dspy_duration_ms"] || 0.0
      }
    }
  end

  defp newest(old, row) do
    cond do
      old["row_evidence_complete"] == true and row["row_evidence_complete"] != true ->
        old

      old["row_evidence_complete"] != true and row["row_evidence_complete"] == true ->
        row

      row["source_generated_at"] >= old["source_generated_at"] ->
        row

      true ->
        old
    end
  end

  defp task_summary(task, expected, rows) do
    {canonical_rows, out_of_range_rows} =
      rows
      |> Enum.sort_by(fn {index, _row} -> index end)
      |> Enum.split_with(fn {index, _row} -> canonical_index?(index, expected) end)

    row_values = Enum.map(canonical_rows, &elem(&1, 1))
    complete_rows = Enum.filter(row_values, & &1["row_evidence_complete"])
    incomplete_rows = length(row_values) - length(complete_rows)

    runner_error_rows =
      Enum.count(
        row_values,
        &(&1["dsex_runner_error"] == true or &1["dspy_runner_error"] == true)
      )

    out_of_range_count = length(out_of_range_rows)
    covered = length(complete_rows)
    dsex_passes = Enum.count(complete_rows, & &1["dsex_passed"])
    dspy_passes = Enum.count(complete_rows, & &1["dspy_passed"])
    dsex_score = safe_div(dsex_passes, covered)
    dspy_score = safe_div(dspy_passes, covered)
    score_delta = dsex_score - dspy_score

    %{
      "task" => task,
      "coverage" => %{
        "covered" => covered,
        "expected" => expected,
        "full" => covered == expected and incomplete_rows == 0 and out_of_range_count == 0,
        "missing_ranges" => missing_ranges(complete_indexes(canonical_rows), expected),
        "incomplete_rows" => incomplete_rows,
        "runner_error_rows" => runner_error_rows,
        "out_of_range_rows" => out_of_range_count
      },
      "dsex_score" => dsex_score,
      "dspy_score" => dspy_score,
      "score_delta" => score_delta,
      "dsex_passes" => dsex_passes,
      "dspy_passes" => dspy_passes,
      "pass_agreement" => count_ratio(complete_rows, "pass_agreement"),
      "answer_agreement" => count_ratio(complete_rows, "answer_agreement"),
      "supporting_metrics" => supporting_metrics(task, complete_rows),
      "disagreements" => disagreement_summary(complete_rows),
      "row_latency" => row_latency_summary(complete_rows),
      "dsex_instrumentation" => dsex_instrumentation_summary(complete_rows),
      "dspy_instrumentation" => runtime_instrumentation_summary(complete_rows, "dspy"),
      "runtime_shape" => runtime_shape_summary(complete_rows),
      "dsex_duration_ms" => summed_unique_task_duration(complete_rows, "dsex_duration_ms"),
      "dspy_duration_ms" => summed_unique_task_duration(complete_rows, "dspy_duration_ms")
    }
  end

  defp canonical_index?(index, expected),
    do: is_integer(index) and index >= 0 and index < expected

  defp complete_indexes(canonical_rows) do
    canonical_rows
    |> Enum.filter(fn {_index, row} -> row["row_evidence_complete"] end)
    |> Enum.map(&elem(&1, 0))
  end

  defp supporting_metrics("hotpotqa", rows) do
    dsex_f1 = average_row_metric(rows, "dsex_metric_metadata", "official_hotpotqa_f1")
    dspy_f1 = average_row_metric(rows, "dspy_metric_metadata", "official_hotpotqa_f1")

    %{
      "official_hotpotqa_f1" => %{
        "dsex" => dsex_f1,
        "dspy" => dspy_f1,
        "delta" => metric_delta(dsex_f1, dspy_f1),
        "coverage" => %{
          "dsex_rows" => row_metric_count(rows, "dsex_metric_metadata", "official_hotpotqa_f1"),
          "dspy_rows" => row_metric_count(rows, "dspy_metric_metadata", "official_hotpotqa_f1"),
          "total_rows" => length(rows)
        },
        "note" =>
          "Supporting evidence only: strict campaign pass/fail remains exact match for this lineage."
      }
    }
  end

  defp supporting_metrics(_task, _rows), do: %{}

  defp disagreement_summary(rows) do
    disagreements =
      rows
      |> Enum.reject(&(&1["pass_agreement"] == true and &1["answer_agreement"] == true))
      |> Enum.sort_by(& &1["absolute_index"])

    pass_disagreements = Enum.count(disagreements, &(&1["pass_agreement"] != true))
    answer_disagreements = Enum.count(disagreements, &(&1["answer_agreement"] != true))

    %{
      "count" => length(disagreements),
      "pass_disagreements" => pass_disagreements,
      "answer_disagreements" => answer_disagreements,
      "directions" => disagreement_directions(disagreements),
      "sample_limit" => @max_disagreement_examples,
      "examples" =>
        disagreements
        |> Enum.take(@max_disagreement_examples)
        |> Enum.map(&disagreement_example/1)
    }
  end

  defp disagreement_directions(rows) do
    rows
    |> Enum.map(&disagreement_direction/1)
    |> Enum.frequencies()
  end

  defp disagreement_direction(%{"dsex_passed" => true, "dspy_passed" => false}),
    do: "dsex_only_pass"

  defp disagreement_direction(%{"dsex_passed" => false, "dspy_passed" => true}),
    do: "dspy_only_pass"

  defp disagreement_direction(%{"dsex_row_present" => false}), do: "missing_dsex_row"
  defp disagreement_direction(%{"dspy_row_present" => false}), do: "missing_dspy_row"
  defp disagreement_direction(_row), do: "answer_or_evidence_mismatch"

  defp disagreement_example(row) do
    %{
      "absolute_index" => row["absolute_index"],
      "index" => row["index"],
      "direction" => disagreement_direction(row),
      "dsex_passed" => row["dsex_passed"],
      "dspy_passed" => row["dspy_passed"],
      "pass_agreement" => row["pass_agreement"],
      "answer_agreement" => row["answer_agreement"],
      "dsex_answer" => compact_sample(row["dsex_answer"]),
      "dspy_answer" => compact_sample(row["dspy_answer"]),
      "dsex_metric_metadata" => compact_metadata(row["dsex_metric_metadata"]),
      "dspy_metric_metadata" => compact_metadata(row["dspy_metric_metadata"]),
      "source_report" => row["source_report"],
      "diagnostic" => compact_diagnostic(row["diagnostic"])
    }
  end

  defp compact_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [
      "official_hotpotqa_em",
      "official_hotpotqa_f1",
      "task_metric",
      "normalized_prediction",
      "normalized_gold"
    ])
  end

  defp compact_metadata(_metadata), do: %{}

  defp compact_diagnostic(%{"dsex" => dsex} = diagnostic) when is_map(diagnostic) do
    %{
      "dsex" => compact_dsex_diagnostic(dsex),
      "dspy_error" => compact_sample(diagnostic["dspy_error"])
    }
  end

  defp compact_diagnostic(_diagnostic), do: %{}

  defp compact_dsex_diagnostic(diagnostic) when is_map(diagnostic) do
    %{
      "question" => compact_sample(diagnostic["question"]),
      "gold_answer" => compact_sample(diagnostic["gold_answer"]),
      "context_sha256" => diagnostic["context_sha256"],
      "context_length" => diagnostic["context_length"],
      "error" => compact_sample(diagnostic["error"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_dsex_diagnostic(_diagnostic), do: nil

  defp compact_sample(nil), do: nil

  defp compact_sample(value) when is_binary(value) do
    if String.length(value) > @max_sample_chars do
      String.slice(value, 0, @max_sample_chars) <> "...[truncated]"
    else
      value
    end
  end

  defp compact_sample(value) when is_map(value) or is_list(value) do
    value
    |> inspect(limit: 20, printable_limit: @max_sample_chars)
    |> compact_sample()
  end

  defp compact_sample(value), do: value

  defp average_row_metric(rows, metadata_key, metric_key) do
    values =
      rows
      |> Enum.map(&get_in(&1, [metadata_key, metric_key]))
      |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      _values -> Enum.sum(values) / length(values)
    end
  end

  defp row_metric_count(rows, metadata_key, metric_key) do
    Enum.count(rows, &is_number(get_in(&1, [metadata_key, metric_key])))
  end

  defp metric_delta(nil, _right), do: nil
  defp metric_delta(_left, nil), do: nil
  defp metric_delta(left, right), do: left - right

  defp row_latency_summary(rows) do
    dsex = row_latency_values(rows, "dsex_duration_ms")
    dspy = row_latency_values(rows, "dspy_duration_ms")

    %{
      "dsex" => distribution(dsex),
      "dspy" => distribution(dspy),
      "ratio_dsex_over_dspy" => %{
        "p50" => ratio(percentile(dsex, 0.5), percentile(dspy, 0.5)),
        "p90" => ratio(percentile(dsex, 0.9), percentile(dspy, 0.9)),
        "p99" => ratio(percentile(dsex, 0.99), percentile(dspy, 0.99)),
        "mean" => ratio(average(dsex), average(dspy))
      }
    }
  end

  defp row_latency_values(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.filter(&is_number/1)
  end

  defp dsex_instrumentation_summary(rows) do
    instrumented = Enum.filter(rows, &(map_size(&1["dsex_instrumentation"] || %{}) > 0))
    lm_duration = instrumentation_values(instrumented, "lm_duration_ms")
    row_duration = row_latency_values(instrumented, "dsex_duration_ms")

    %{
      "coverage" => %{
        "instrumented_rows" => length(instrumented),
        "total_rows" => length(rows),
        "complete" => length(instrumented) == length(rows)
      },
      "lm_calls" => instrumentation_sum(instrumented, "lm_calls"),
      "json_fallbacks" => instrumentation_sum(instrumented, "json_fallbacks"),
      "parse_retries" => instrumentation_sum(instrumented, "parse_retries"),
      "lm_duration" => distribution(lm_duration),
      "local_overhead_ms" => distribution(local_overhead_values(instrumented)),
      "lm_duration_share" => %{
        "mean" => ratio(average(lm_duration), average(row_duration)),
        "total" => ratio(Enum.sum(lm_duration), Enum.sum(row_duration))
      },
      "message_chars" => char_distribution(instrumentation_values(instrumented, "message_chars")),
      "raw_chars" => char_distribution(instrumentation_values(instrumented, "raw_chars")),
      "note" =>
        "DSEx-only benchmark instrumentation. lm_duration_share near 1.0 means live latency is dominated by provider/model time rather than local adapter/metric overhead."
    }
  end

  defp runtime_instrumentation_summary(rows, runtime) do
    instrumentation_key = "#{runtime}_instrumentation"
    duration_key = "#{runtime}_duration_ms"
    instrumented = Enum.filter(rows, &(map_size(&1[instrumentation_key] || %{}) > 0))
    lm_duration = instrumentation_values(instrumented, instrumentation_key, "lm_duration_ms")
    row_duration = row_latency_values(instrumented, duration_key)

    %{
      "coverage" => %{
        "instrumented_rows" => length(instrumented),
        "total_rows" => length(rows),
        "complete" => length(instrumented) == length(rows)
      },
      "lm_calls" => instrumentation_sum(instrumented, instrumentation_key, "lm_calls"),
      "lm_duration" => distribution(lm_duration),
      "lm_duration_share" => %{
        "mean" => ratio(average(lm_duration), average(row_duration)),
        "total" => ratio(Enum.sum(lm_duration), Enum.sum(row_duration))
      },
      "message_chars" =>
        char_distribution(
          instrumentation_values(instrumented, instrumentation_key, "message_chars")
        ),
      "input_chars" =>
        char_distribution(
          instrumentation_values(instrumented, instrumentation_key, "input_chars")
        ),
      "raw_chars" =>
        char_distribution(instrumentation_values(instrumented, instrumentation_key, "raw_chars")),
      "prediction_chars" =>
        char_distribution(
          instrumentation_values(instrumented, instrumentation_key, "prediction_chars")
        ),
      "message_chars_sources" =>
        instrumentation_value_counts(instrumented, instrumentation_key, "message_chars_source"),
      "raw_chars_sources" =>
        instrumentation_value_counts(instrumented, instrumentation_key, "raw_chars_source"),
      "history_found" =>
        count_truthy_instrumentation(instrumented, instrumentation_key, "history_found")
    }
  end

  defp runtime_shape_summary(rows) do
    message_pairs = paired_instrumentation_values(rows, "message_chars")
    raw_pairs = paired_instrumentation_values(rows, "raw_chars")
    total_rows = length(rows)

    %{
      "message_chars_ratio_dsex_over_dspy_mean" => ratio_from_pairs(message_pairs),
      "raw_chars_ratio_dsex_over_dspy_mean" => ratio_from_pairs(raw_pairs),
      "coverage" => %{
        "total_rows" => total_rows,
        "message_chars_comparable_rows" => length(message_pairs),
        "raw_chars_comparable_rows" => length(raw_pairs),
        "complete" =>
          total_rows > 0 and length(message_pairs) == total_rows and
            length(raw_pairs) == total_rows
      },
      "note" =>
        "Shape ratios use rows where both sides exposed comparable instrumentation. Coverage is complete only when every covered row has comparable DSEx and DSPy shape instrumentation."
    }
  end

  defp paired_instrumentation_values(rows, key) do
    rows
    |> Enum.flat_map(fn row ->
      with dsex when is_number(dsex) <- get_in(row, ["dsex_instrumentation", key]),
           dspy when is_number(dspy) <- get_in(row, ["dspy_instrumentation", key]) do
        [{dsex, dspy}]
      else
        _other -> []
      end
    end)
  end

  defp ratio_from_pairs([]), do: nil

  defp ratio_from_pairs(pairs) do
    dsex = Enum.map(pairs, fn {dsex, _dspy} -> dsex end)
    dspy = Enum.map(pairs, fn {_dsex, dspy} -> dspy end)
    ratio(average(dsex), average(dspy))
  end

  defp instrumentation_values(rows, key) do
    rows
    |> Enum.map(&get_in(&1, ["dsex_instrumentation", key]))
    |> Enum.filter(&is_number/1)
  end

  defp instrumentation_sum(rows, key), do: rows |> instrumentation_values(key) |> Enum.sum()

  defp instrumentation_values(rows, instrumentation_key, key) do
    rows
    |> Enum.map(&get_in(&1, [instrumentation_key, key]))
    |> Enum.filter(&is_number/1)
  end

  defp instrumentation_sum(rows, instrumentation_key, key),
    do: rows |> instrumentation_values(instrumentation_key, key) |> Enum.sum()

  defp count_truthy_instrumentation(rows, instrumentation_key, key) do
    Enum.count(rows, &(get_in(&1, [instrumentation_key, key]) == true))
  end

  defp instrumentation_value_counts(rows, instrumentation_key, key) do
    rows
    |> Enum.map(&get_in(&1, [instrumentation_key, key]))
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
  end

  defp local_overhead_values(rows) do
    rows
    |> Enum.map(fn row ->
      with duration when is_number(duration) <- row["dsex_duration_ms"],
           lm_duration when is_number(lm_duration) <-
             get_in(row, ["dsex_instrumentation", "lm_duration_ms"]) do
        max(duration - lm_duration, 0.0)
      else
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp distribution(values) do
    %{
      "count" => length(values),
      "mean_ms" => average(values),
      "p50_ms" => percentile(values, 0.5),
      "p90_ms" => percentile(values, 0.9),
      "p99_ms" => percentile(values, 0.99),
      "max_ms" => Enum.max(values, fn -> nil end)
    }
  end

  defp char_distribution(values) do
    %{
      "count" => length(values),
      "mean_chars" => average(values),
      "p50_chars" => percentile(values, 0.5),
      "p90_chars" => percentile(values, 0.9),
      "p99_chars" => percentile(values, 0.99),
      "max_chars" => Enum.max(values, fn -> nil end)
    }
  end

  defp percentile([], _q), do: nil

  defp percentile(values, q) do
    sorted = Enum.sort(values)
    index = min(max(ceil(length(sorted) * q) - 1, 0), length(sorted) - 1)
    Enum.at(sorted, index)
  end

  defp next_chunks(task_reports) do
    Enum.map(task_reports, fn task ->
      next_range = List.first(task["coverage"]["missing_ranges"])

      %{
        "task" => task["task"],
        "next_offset" => next_range && next_range["from"],
        "remaining" => task["coverage"]["expected"] - task["coverage"]["covered"]
      }
    end)
  end

  defp count_ratio(rows, key) do
    %{
      "count" => Enum.count(rows, & &1[key]),
      "total" => length(rows),
      "ratio" => safe_div(Enum.count(rows, & &1[key]), length(rows))
    }
  end

  defp summed_unique_task_duration(rows, key) do
    rows
    |> Enum.group_by(& &1["source_report"])
    |> Enum.map(fn {_path, rows} ->
      rows |> List.first() |> get_in(["task_duration", key]) || 0.0
    end)
    |> Enum.sum()
  end

  defp missing_ranges(indexes, expected) do
    present = MapSet.new(indexes)

    0..max(expected - 1, 0)
    |> Enum.reject(&MapSet.member?(present, &1))
    |> ranges()
    |> Enum.take(50)
  end

  defp ranges([]), do: []

  defp ranges([first | rest]) do
    {ranges, start, last} =
      Enum.reduce(rest, {[], first, first}, fn
        index, {acc, start, last} when index == last + 1 ->
          {acc, start, index}

        index, {acc, start, last} ->
          {[%{"from" => start, "to" => last} | acc], index, index}
      end)

    Enum.reverse([%{"from" => start, "to" => last} | ranges])
  end

  defp source_reports(reports) do
    Enum.map(reports, fn report ->
      %{
        "path" => report["__path__"],
        "generated_at" => report["generated_at"],
        "campaign_id" => report["campaign_id"],
        "provider" => report_provider(report),
        "model" => report_model(report),
        "max_concurrency" => report_max_concurrency(report),
        "generation" => report["generation"],
        "runner_order" => report["runner_order"] || "dsex_first",
        "coverage" => report["evidence"]
      }
    end)
  end

  defp runner_order_summary(reports) do
    values =
      reports
      |> Enum.map(&(&1["runner_order"] || "dsex_first"))
      |> Enum.frequencies()

    %{
      "values" => values,
      "mixed" => map_size(values) > 1,
      "balanced" => balanced_runner_order?(values),
      "note" =>
        "Older artifacts without runner_order are treated as dsex_first. Mixed or balanced order reduces live-provider warmup/order bias in latency evidence."
    }
  end

  defp balanced_runner_order?(%{"dsex_first" => left, "dspy_first" => right}) do
    abs(left - right) <= 1
  end

  defp balanced_runner_order?(_values), do: false

  defp execution_summary(reports) do
    max_concurrency_values =
      reports
      |> Enum.map(&report_max_concurrency/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "max_concurrency_values" => max_concurrency_values,
      "max_concurrency" =>
        case max_concurrency_values do
          [value] -> value
          _other -> nil
        end,
      "max_concurrency_consistent" => length(max_concurrency_values) <= 1,
      "source_count" => length(reports),
      "note" =>
        "Full live parity requires DSEx and DSPy campaign chunks to use one consistent max_concurrency setting; runner_order may vary intentionally to balance order bias."
    }
  end

  defp generation_summary(reports) do
    values =
      reports
      |> Enum.map(&Map.get(&1, "generation"))
      |> Enum.reject(&is_nil/1)

    normalized =
      values
      |> Enum.map(&canonical_generation/1)
      |> Enum.uniq()

    %{
      "consistent" => length(normalized) <= 1 and length(values) == length(reports),
      "value" => List.first(normalized),
      "source_count" => length(reports),
      "recorded_count" => length(values),
      "distinct_values" => normalized,
      "effective" => effective_generation_summary(values)
    }
  end

  defp canonical_generation(generation) do
    generation = generation || %{}

    generation
    |> Map.take(["temperature", "max_tokens", "reasoning_effort", "prompt_contract"])
    |> maybe_put("dsex_transport", get_in(generation, ["dsex", "transport"]))
    |> Map.put_new("prompt_contract", "legacy-unrecorded")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp effective_generation_summary(values) do
    dsex_values = Enum.map(values, &get_in(&1, ["dsex", "effective"]))
    dspy_values = Enum.map(values, &get_in(&1, ["dspy", "effective"]))
    dsex_wire_api_values = Enum.map(values, &get_in(&1, ["dsex", "wire_api"]))
    dspy_wire_api_values = Enum.map(values, &get_in(&1, ["dspy", "wire_api"]))

    dsex =
      dsex_values
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    dspy =
      dspy_values
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    dsex_recorded_count = length(Enum.reject(dsex_values, &is_nil/1))
    dspy_recorded_count = length(Enum.reject(dspy_values, &is_nil/1))
    complete = dsex_recorded_count == length(values) and dspy_recorded_count == length(values)

    dsex_wire_api =
      dsex_wire_api_values
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    dspy_wire_api =
      dspy_wire_api_values
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    dsex_wire_family = Enum.map(dsex_wire_api, &wire_api_family/1) |> Enum.uniq()
    dspy_wire_family = Enum.map(dspy_wire_api, &wire_api_family/1) |> Enum.uniq()

    dsex_wire_api_recorded_count = length(Enum.reject(dsex_wire_api_values, &is_nil/1))
    dspy_wire_api_recorded_count = length(Enum.reject(dspy_wire_api_values, &is_nil/1))

    wire_api_complete =
      dsex_wire_api_recorded_count == length(values) and
        dspy_wire_api_recorded_count == length(values)

    %{
      "complete" => complete,
      "dsex_recorded_count" => dsex_recorded_count,
      "dspy_recorded_count" => dspy_recorded_count,
      "dsex_distinct" => dsex,
      "dspy_distinct" => dspy,
      "matched" => complete and dsex == dspy and dsex != [],
      "wire_api_complete" => wire_api_complete,
      "dsex_wire_api_recorded_count" => dsex_wire_api_recorded_count,
      "dspy_wire_api_recorded_count" => dspy_wire_api_recorded_count,
      "dsex_wire_api_distinct" => dsex_wire_api,
      "dspy_wire_api_distinct" => dspy_wire_api,
      "dsex_wire_endpoint_families" => dsex_wire_family,
      "dspy_wire_endpoint_families" => dspy_wire_family,
      "wire_api_matched" =>
        wire_api_complete and dsex_wire_family == dspy_wire_family and dsex_wire_family != []
    }
  end

  defp wire_api_family("openai_responses"), do: "openai_responses"
  defp wire_api_family("openai_chat_completions"), do: "openai_chat_completions"
  defp wire_api_family("litellm_chat_completion"), do: "openai_chat_completions"

  defp wire_api_family("litellm_chat_completion_with_max_completion_tokens"),
    do: "openai_chat_completions"

  defp wire_api_family("anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("litellm_anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("google_generate_content"), do: "google_generate_content"
  defp wire_api_family("litellm_google_generate_content"), do: "google_generate_content"

  defp wire_api_family(other), do: other

  defp report_model(report),
    do: get_in(report, ["dsex", "model", "model"]) || get_in(report, ["dspy", "model", "model"])

  defp report_provider(report), do: get_in(report, ["dsex", "model", "provider"]) || "unknown"

  defp report_identity(report),
    do: %{"provider" => report_provider(report), "model" => report_model(report)}

  defp report_max_concurrency(report) do
    report
    |> Map.get("tasks", [])
    |> Enum.map(&(&1["max_concurrency"] || 1))
    |> Enum.max(fn -> 1 end)
  end

  defp one_identity!([identity]), do: identity

  defp one_identity!(identities) do
    Mix.raise(
      "parity aggregation requires one DSEx provider/model identity, got #{inspect(identities)}; pass --provider/--model or a provider-specific --in glob"
    )
  end

  defp one_generation!([generation]), do: generation

  defp one_generation!(generations) do
    Mix.raise(
      "parity aggregation requires one generation setting, got #{inspect(generations)}; rerun or aggregate temperature/max_tokens lanes separately"
    )
  end

  defp parity_note(
         false,
         _aggregate_gap,
         _max_task_gap,
         _strict_aggregate_gap,
         _strict_task_gap,
         _latency_ratio,
         _max_latency_ratio,
         _execution_consistent?
       ) do
    "Full parity cannot be claimed because not every canonical benchmark row is covered."
  end

  defp parity_note(
         true,
         _aggregate_gap,
         _max_task_gap,
         _strict_aggregate_gap,
         _strict_task_gap,
         _latency_ratio,
         _max_latency_ratio,
         false
       ) do
    "Full coverage passed, but campaign chunks do not use one consistent max_concurrency setting."
  end

  defp parity_note(
         true,
         aggregate_gap,
         max_task_gap,
         strict_aggregate_gap,
         strict_task_gap,
         latency_ratio,
         max_latency_ratio,
         true
       )
       when aggregate_gap <= strict_aggregate_gap + 1.0e-12 and
              max_task_gap <= strict_task_gap + 1.0e-12 and
              (is_nil(latency_ratio) or latency_ratio <= max_latency_ratio + 1.0e-12) do
    "Full coverage and strict score parity passed."
  end

  defp parity_note(
         true,
         _aggregate_gap,
         _max_task_gap,
         _strict_aggregate_gap,
         _strict_task_gap,
         _latency_ratio,
         _max_latency_ratio,
         _execution_consistent?
       ) do
    "Full coverage passed, but strict score or latency parity did not."
  end

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp average([]), do: nil
  defp average(values), do: Enum.sum(values) / length(values)

  defp within?(value, threshold), do: value <= threshold + 1.0e-12
  defp latency_within?(nil, _threshold), do: true
  defp latency_within?(value, threshold), do: value <= threshold + 1.0e-12

  defp ratio(nil, _right), do: nil
  defp ratio(_left, nil), do: nil
  defp ratio(_left, 0), do: nil
  defp ratio(left, right), do: Float.round(left / right, 3)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end

  defp model_slug(model) when is_binary(model),
    do: String.replace(model, ~r/[^0-9A-Za-z_.-]/, "_")

  defp model_slug(model), do: model |> inspect() |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")
end
