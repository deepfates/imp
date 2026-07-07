defmodule Mix.Tasks.Dsex.Benchmark.Parity.Aggregate do
  @moduledoc """
  Aggregate DSEx-vs-DSPy parity chunk artifacts into one campaign report.

      mix dsex.benchmark.parity.aggregate --model gpt-5.4-mini

  The aggregator is row-based: each `(task, absolute_index)` is counted once,
  and the newest artifact wins when chunks overlap. This prevents smoke runs
  from inflating coverage or score totals.
  """

  use Mix.Task

  @shortdoc "Aggregate DSEx-vs-DSPy parity chunk reports"
  @full_lengths %{"gsm8k" => 1319, "hotpotqa" => 7405}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          in: :string,
          out: :string,
          model: :string,
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

    if reports == [] do
      Mix.raise("no parity reports matched #{input_glob}")
    end

    aggregate =
      aggregate_reports(reports,
        strict_task_gap: Keyword.get(opts, :strict_task_gap, 0.01),
        strict_aggregate_gap: Keyword.get(opts, :strict_aggregate_gap, 0.01),
        max_latency_ratio: Keyword.get(opts, :max_latency_ratio, 1.5)
      )

    out_path =
      Path.join(
        out_dir,
        "dsex-dspy-parity-campaign-#{model_slug(aggregate["model"])}-#{timestamp_slug()}.json"
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

  defp aggregate_reports(reports, opts) do
    model = reports |> Enum.map(&report_model/1) |> Enum.uniq() |> one_model!()
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
    full_coverage? = covered == expected

    latency_ratio =
      ratio(
        Enum.sum(Enum.map(task_reports, & &1["dsex_duration_ms"])),
        Enum.sum(Enum.map(task_reports, & &1["dspy_duration_ms"]))
      )

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => model,
      "source_reports" => source_reports(reports),
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
          full_coverage? and within?(aggregate_gap, strict_aggregate_gap) and
            within?(max_task_gap, strict_task_gap) and
            latency_within?(latency_ratio, max_latency_ratio),
        "full_coverage" => full_coverage?,
        "latency_parity" => latency_within?(latency_ratio, max_latency_ratio),
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
            max_latency_ratio
          )
      }
    }
  end

  defp rows_by_task(reports) do
    Enum.reduce(reports, %{}, fn report, acc ->
      Enum.reduce(report["tasks"] || [], acc, fn task, task_acc ->
        task_name = task["task"]
        offset = task["offset"] || 0
        generated_at = report["generated_at"] || ""

        task_rows =
          task
          |> Map.get("row_agreement", [])
          |> Enum.map(fn row ->
            absolute_index = row["absolute_index"] || offset + row["index"]
            {absolute_index, row_record(report, task, row, absolute_index, generated_at)}
          end)

        Map.update(task_acc, task_name, Map.new(task_rows), fn existing ->
          Enum.reduce(task_rows, existing, fn {index, row}, rows ->
            Map.update(rows, index, row, fn old -> newest(old, row) end)
          end)
        end)
      end)
    end)
  end

  defp row_record(report, task, row, absolute_index, generated_at) do
    %{
      "absolute_index" => absolute_index,
      "index" => row["index"],
      "dsex_passed" => row["dsex_passed"] == true,
      "dspy_passed" => row["dspy_passed"] == true,
      "pass_agreement" => row["pass_agreement"] == true,
      "answer_agreement" => row["answer_agreement"] == true,
      "dsex_answer" => row["dsex_answer"],
      "dspy_answer" => row["dspy_answer"],
      "source_report" => report["__path__"],
      "source_generated_at" => generated_at,
      "task_duration" => %{
        "dsex_duration_ms" => task["dsex_duration_ms"] || 0.0,
        "dspy_duration_ms" => task["dspy_duration_ms"] || 0.0
      }
    }
  end

  defp newest(old, row) do
    if row["source_generated_at"] >= old["source_generated_at"], do: row, else: old
  end

  defp task_summary(task, expected, rows) do
    row_values = rows |> Enum.sort_by(fn {index, _row} -> index end) |> Enum.map(&elem(&1, 1))
    covered = length(row_values)
    dsex_passes = Enum.count(row_values, & &1["dsex_passed"])
    dspy_passes = Enum.count(row_values, & &1["dspy_passed"])
    dsex_score = safe_div(dsex_passes, covered)
    dspy_score = safe_div(dspy_passes, covered)
    score_delta = dsex_score - dspy_score

    %{
      "task" => task,
      "coverage" => %{
        "covered" => covered,
        "expected" => expected,
        "full" => covered == expected,
        "missing_ranges" => missing_ranges(Map.keys(rows), expected)
      },
      "dsex_score" => dsex_score,
      "dspy_score" => dspy_score,
      "score_delta" => score_delta,
      "dsex_passes" => dsex_passes,
      "dspy_passes" => dspy_passes,
      "pass_agreement" => count_ratio(row_values, "pass_agreement"),
      "answer_agreement" => count_ratio(row_values, "answer_agreement"),
      "dsex_duration_ms" => summed_unique_task_duration(row_values, "dsex_duration_ms"),
      "dspy_duration_ms" => summed_unique_task_duration(row_values, "dspy_duration_ms")
    }
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
        "model" => report_model(report),
        "max_concurrency" => report_max_concurrency(report),
        "coverage" => report["evidence"]
      }
    end)
  end

  defp report_model(report),
    do: get_in(report, ["dsex", "model", "model"]) || get_in(report, ["dspy", "model", "model"])

  defp report_max_concurrency(report) do
    report
    |> Map.get("tasks", [])
    |> Enum.map(&(&1["max_concurrency"] || 1))
    |> Enum.max(fn -> 1 end)
  end

  defp one_model!([model]), do: model

  defp one_model!(models) do
    Mix.raise(
      "parity aggregation requires one model, got #{inspect(models)}; pass --model or a model-specific --in glob"
    )
  end

  defp parity_note(
         false,
         _aggregate_gap,
         _max_task_gap,
         _strict_aggregate_gap,
         _strict_task_gap,
         _latency_ratio,
         _max_latency_ratio
       ) do
    "Full parity cannot be claimed because not every canonical benchmark row is covered."
  end

  defp parity_note(
         true,
         aggregate_gap,
         max_task_gap,
         strict_aggregate_gap,
         strict_task_gap,
         latency_ratio,
         max_latency_ratio
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
         _max_latency_ratio
       ) do
    "Full coverage passed, but strict score or latency parity did not."
  end

  defp safe_div(_numerator, 0), do: 0.0
  defp safe_div(numerator, denominator), do: numerator / denominator

  defp within?(value, threshold), do: value <= threshold + 1.0e-12
  defp latency_within?(nil, _threshold), do: true
  defp latency_within?(value, threshold), do: value <= threshold + 1.0e-12

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
