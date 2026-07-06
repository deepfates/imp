defmodule Mix.Tasks.Dsex.Benchmark.Parity do
  @moduledoc """
  Compare DSEx against the real Python DSPy package on the same benchmark rows.

      mix dsex.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2

  The task expects Python DSPy to be installed. By default it uses
  `tmp/dspy-parity-venv/bin/python` when present.
  """

  use Mix.Task

  @shortdoc "Run DSEx-vs-DSPy live parity comparison"
  @default_models ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5", "gpt-4.1"]
  @full_lengths %{"gsm8k" => 1319, "hotpotqa" => 7405}

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          gsm8k: :string,
          hotpotqa: :string,
          offset: :integer,
          max_examples: :integer,
          out: :string,
          model: :string,
          models: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    tasks = tasks(opts)

    if tasks == [] do
      Mix.raise("provide at least one dataset path with --gsm8k or --hotpotqa")
    end

    api_key = System.get_env("OPENAI_API_KEY") || Mix.raise("OPENAI_API_KEY is required")
    models = models(opts, api_key)
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    max_examples = Keyword.get(opts, :max_examples, 20)
    File.mkdir_p!(out_dir)

    Enum.each(models, fn model ->
      run_model!(opts, tasks, model, api_key, max_examples, out_dir)
    end)
  end

  defp run_model!(opts, tasks, model, api_key, max_examples, out_dir) do
    dsex =
      DSEx.BenchmarkTruth.run(
        tasks: tasks,
        mode: :live,
        lm: DSEx.openai(model, api_key: api_key),
        model: %{provider: "openai-compatible", model: model},
        out_dir: out_dir,
        offset: Keyword.get(opts, :offset, 0),
        max_examples: max_examples,
        optimizer_comparisons: false
      )

    dspy_path =
      run_dspy!(
        python(opts),
        tasks,
        model,
        Keyword.get(opts, :offset, 0),
        max_examples,
        out_dir
      )

    dspy = dspy_path |> File.read!() |> Jason.decode!()
    report = parity_report(dsex.report, dspy)

    out_path =
      Path.join(out_dir, "dsex-dspy-parity-#{model_slug(model)}-#{timestamp_slug()}.json")

    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("dsex report: #{dsex.out_path}")
    Mix.shell().info("dspy report: #{dspy_path}")
    Mix.shell().info("parity report: #{out_path}")
    Mix.shell().info("aggregate score delta: #{report["aggregate"]["score_delta"]}")
  end

  defp models(opts, api_key) do
    cond do
      Keyword.has_key?(opts, :models) ->
        opts |> Keyword.fetch!(:models) |> split_csv()

      Keyword.has_key?(opts, :model) ->
        [Keyword.fetch!(opts, :model)]

      model = System.get_env("OPENAI_MODEL") ->
        [model]

      true ->
        [discover_default_model(api_key)]
    end
  end

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp discover_default_model(api_key) do
    available = openai_models(api_key)
    Enum.find(@default_models, "gpt-5.5", &(&1 in available))
  end

  defp openai_models(api_key) do
    :inets.start()
    :ssl.start()

    base_url = System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"
    url = String.trim_trailing(base_url, "/") <> "/models"
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        body
        |> Jason.decode!()
        |> Map.get("data", [])
        |> Enum.map(& &1["id"])

      _other ->
        []
    end
  end

  defp tasks(opts) do
    []
    |> maybe_put(:gsm8k, Keyword.get(opts, :gsm8k))
    |> maybe_put(:hotpotqa, Keyword.get(opts, :hotpotqa))
  end

  defp maybe_put(tasks, _task, nil), do: tasks
  defp maybe_put(tasks, task, path), do: [{task, path} | tasks] |> Enum.reverse()

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
  end

  defp run_dspy!(python, tasks, model, offset, max_examples, out_dir) do
    args =
      [
        "scripts/dspy_parity_runner.py",
        "--model",
        model,
        "--offset",
        to_string(offset),
        "--max-examples",
        to_string(max_examples),
        "--out",
        out_dir
      ] ++
        Enum.flat_map(tasks, fn {task, path} -> ["--#{task}", path] end)

    case System.cmd(python, args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.find(&String.ends_with?(&1, ".json"))
        |> case do
          nil -> Mix.raise("DSPy runner did not print a report path:\n#{output}")
          path -> path
        end

      {output, status} ->
        Mix.raise("DSPy runner failed with status #{status}:\n#{output}")
    end
  end

  defp parity_report(dsex, dspy) do
    dsex_tasks = Map.new(dsex["tasks"], &{&1["task"], &1})
    dspy_tasks = Map.new(dspy["tasks"], &{&1["task"], &1})
    task_names = Enum.sort((Map.keys(dsex_tasks) ++ Map.keys(dspy_tasks)) |> Enum.uniq())

    tasks =
      Enum.map(task_names, fn task ->
        compare_task(task, dsex_tasks[task], dspy_tasks[task])
      end)

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "dsex" => Map.take(dsex, ["git_sha", "elixir", "otp", "model", "mode"]),
      "dspy" => Map.take(dspy, ["git_sha", "python", "dspy_version", "model", "mode"]),
      "aggregate" => %{
        "dsex_score" => dsex["aggregate_score"],
        "dspy_score" => dspy["aggregate_score"],
        "score_delta" => dsex["aggregate_score"] - dspy["aggregate_score"],
        "dsex_duration_ms" => total_duration(dsex["tasks"]),
        "dspy_duration_ms" => total_duration(dspy["tasks"]),
        "latency_ratio_dsex_over_dspy" =>
          ratio(total_duration(dsex["tasks"]), total_duration(dspy["tasks"]))
      },
      "tasks" => tasks,
      "evidence" => evidence_summary(tasks),
      "parity" => parity_summary(tasks, dsex["aggregate_score"], dspy["aggregate_score"])
    }
  end

  defp compare_task(task, dsex, dspy) do
    %{
      "task" => task,
      "offset" => max((dsex && dsex["offset"]) || 0, (dspy && dspy["offset"]) || 0),
      "examples" => max((dsex && dsex["examples"]) || 0, (dspy && dspy["examples"]) || 0),
      "dsex_score" => dsex && dsex["score"],
      "dspy_score" => dspy && dspy["score"],
      "score_delta" => score_delta(dsex, dspy),
      "dsex_duration_ms" => dsex && dsex["duration_ms"],
      "dspy_duration_ms" => dspy && dspy["duration_ms"],
      "latency_ratio_dsex_over_dspy" =>
        ratio(dsex && dsex["duration_ms"], dspy && dspy["duration_ms"]),
      "dsex_errors" => dsex |> errors(),
      "dspy_errors" => dspy |> errors(),
      "row_agreement" => row_agreement(dsex, dspy)
    }
  end

  defp row_agreement(nil, _dspy), do: []
  defp row_agreement(_dsex, nil), do: []

  defp row_agreement(dsex, dspy) do
    dspy_rows = Map.new(dspy["rows"], &{&1["index"], &1})

    Enum.map(dsex["rows"], fn row ->
      other = dspy_rows[row["index"]]

      %{
        "index" => row["index"],
        "dsex_passed" => row["passed"],
        "dspy_passed" => other && other["passed"],
        "pass_agreement" => other && row["passed"] == other["passed"],
        "answer_agreement" =>
          other &&
            normalize_answer(answer(row)) ==
              normalize_answer(get_in(other, ["prediction", "answer"])),
        "dsex_answer" => answer(row),
        "dspy_answer" => other && get_in(other, ["prediction", "answer"])
      }
    end)
  end

  defp answer(%{"prediction" => nil}), do: nil

  defp answer(%{"prediction" => prediction}) when is_map(prediction) do
    Map.get(prediction, "answer") || Map.get(prediction, :answer)
  end

  defp answer(_row), do: nil

  defp evidence_summary(tasks) do
    examples = tasks |> Enum.map(&(&1["examples"] || 0)) |> Enum.sum()
    full_examples = tasks |> Enum.map(&Map.get(@full_lengths, &1["task"], 0)) |> Enum.sum()

    %{
      "examples" => examples,
      "full_examples" => full_examples,
      "scale" => evidence_scale(examples, full_examples),
      "adequate_for_research_sample" => examples >= 200 or examples == full_examples,
      "adequate_for_full_parity_claim" => examples == full_examples and full_examples > 0,
      "note" =>
        "Smoke samples prove wiring only. Use full fetched manifests and repeated current-model runs before making production parity claims."
    }
  end

  defp evidence_scale(examples, full_examples)
       when examples == full_examples and full_examples > 0,
       do: "full"

  defp evidence_scale(examples, _full_examples) when examples >= 200, do: "research_sample"
  defp evidence_scale(_examples, _full_examples), do: "smoke"

  defp parity_summary(tasks, dsex_score, dspy_score) do
    task_score_gaps = Enum.map(tasks, &abs(&1["score_delta"] || 0.0))
    max_task_gap = Enum.max(task_score_gaps, fn -> 0.0 end)
    score_parity? = abs(dsex_score - dspy_score) <= 0.01 and max_task_gap <= 0.01

    %{
      "score_parity" => score_parity?,
      "max_task_score_gap" => max_task_gap,
      "note" => parity_note(score_parity?)
    }
  end

  defp parity_note(true) do
    "Strict score parity passed on this sample. Latency is reported as evidence, not pass/fail, because provider variance and DSPy retries/cache behavior can dominate small runs."
  end

  defp parity_note(false) do
    "Strict score parity did not pass on this sample. Inspect task score gaps and row-level pass/answer agreement before making parity claims."
  end

  defp score_delta(nil, _dspy), do: nil
  defp score_delta(_dsex, nil), do: nil
  defp score_delta(dsex, dspy), do: dsex["score"] - dspy["score"]

  defp errors(nil), do: nil
  defp errors(task), do: length(task["errors"] || [])

  defp total_duration(tasks), do: Enum.sum(Enum.map(tasks || [], &(&1["duration_ms"] || 0.0)))

  defp ratio(_left, nil), do: nil
  defp ratio(_left, 0), do: nil
  defp ratio(nil, _right), do: nil
  defp ratio(left, right), do: Float.round(left / right, 3)

  defp normalize_answer(nil), do: nil

  defp normalize_answer(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in ["a", "an", "the"]))
    |> Enum.join(" ")
  end

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

  defp model_slug(model), do: String.replace(model, ~r/[^0-9A-Za-z_.-]/, "_")
end
