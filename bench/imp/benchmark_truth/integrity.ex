defmodule Imp.BenchmarkTruth.Integrity do
  @moduledoc false

  @type task_name :: :gsm8k | :hotpotqa

  def check(tasks, opts \\ []) do
    out_dir = Keyword.get(opts, :out_dir, Imp.BenchmarkTruth.Paths.runs("integrity"))
    File.mkdir_p!(out_dir)

    task_results =
      tasks
      |> Enum.map(fn {task, path} -> check_task(task, path) end)

    report = %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tasks" => task_results,
      "passing" => Enum.all?(task_results, & &1["passing"])
    }

    out_path = Path.join(out_dir, "benchmark-data-integrity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")
    %{report: report, out_path: out_path}
  end

  def check_task(:gsm8k, path) do
    rows = read_jsonl(path)

    issues =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, index} -> gsm8k_issues(row, index) end)

    task_summary(:gsm8k, path, rows, issues)
  end

  def check_task(:hotpotqa, path) do
    rows = read_jsonl(path)

    issues =
      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, index} -> hotpotqa_issues(row, index) end)

    task_summary(:hotpotqa, path, rows, issues)
  end

  defp task_summary(task, path, rows, issues) do
    blocking = Enum.filter(issues, &(&1["severity"] == "error"))

    %{
      "task" => Atom.to_string(task),
      "path" => path,
      "sha256" => file_sha256(path),
      "rows" => length(rows),
      "passing" => blocking == [],
      "issue_count" => length(issues),
      "error_count" => length(blocking),
      "warning_count" => Enum.count(issues, &(&1["severity"] == "warning")),
      "issues" => issues
    }
  end

  defp gsm8k_issues(row, index) do
    []
    |> require_nonblank(row, index, "question")
    |> require_nonblank(row, index, "answer")
    |> require_nonblank(row, index, "canonical_answer")
  end

  defp hotpotqa_issues(row, index) do
    context = to_string(row["context"] || "")
    supporting_titles = row |> get_in(["supporting_facts", "title"]) |> List.wrap()
    answer = to_string(row["answer"] || "")

    []
    |> require_nonblank(row, index, "question")
    |> require_nonblank(row, index, "context")
    |> require_nonblank(row, index, "answer")
    |> require_supporting_titles(index, context, supporting_titles)
    |> maybe_warn_answer_absent(index, context, answer)
  end

  defp require_nonblank(issues, row, index, field) do
    case Map.get(row, field) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: [issue(index, "error", "#{field}_blank") | issues],
          else: issues

      nil ->
        [issue(index, "error", "#{field}_missing") | issues]

      _value ->
        issues
    end
  end

  defp require_supporting_titles(issues, index, _context, []),
    do: [issue(index, "error", "supporting_fact_titles_missing") | issues]

  defp require_supporting_titles(issues, index, context, titles) do
    titles
    |> Enum.uniq()
    |> Enum.reject(&title_present?(context, &1))
    |> Enum.reduce(issues, fn title, acc ->
      [
        issue(index, "error", "supporting_fact_title_absent_from_context", %{"title" => title})
        | acc
      ]
    end)
  end

  defp maybe_warn_answer_absent(issues, _index, _context, answer) when answer in ["yes", "no"],
    do: issues

  defp maybe_warn_answer_absent(issues, index, context, answer) do
    if answer != "" and not contains_normalized?(context, answer) do
      [issue(index, "warning", "answer_absent_from_context", %{"answer" => answer}) | issues]
    else
      issues
    end
  end

  defp title_present?(context, title), do: String.contains?(context, "#{title}:")

  defp contains_normalized?(haystack, needle) do
    haystack
    |> normalize()
    |> String.contains?(normalize(needle))
  end

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp issue(index, severity, code, extra \\ %{}) do
    Map.merge(%{"index" => index, "severity" => severity, "code" => code}, extra)
  end

  defp read_jsonl(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp file_sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp timestamp_slug do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
