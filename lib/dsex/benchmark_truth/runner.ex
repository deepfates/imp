defmodule DSEx.BenchmarkTruth.Runner do
  @moduledoc """
  Run DSEx programs over canonical benchmark JSONL files and write audit artifacts.

  `:fixture` mode uses an oracle LM derived from the dataset rows. It proves the
  benchmark harness, data loading, metrics, and artifact schema without spending
  provider tokens. `:live` mode uses the caller-supplied LM and records model
  metadata for research evidence.
  """

  @default_out_dir "benchmarks/results"

  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :fixture)
    tasks = Keyword.fetch!(opts, :tasks)
    out_dir = Keyword.get(opts, :out_dir, @default_out_dir)
    max_examples = Keyword.get(opts, :max_examples, 20)
    lm = Keyword.get(opts, :lm)

    File.mkdir_p!(out_dir)

    task_results =
      tasks
      |> Enum.map(fn {task, path} ->
        run_task(task, path, mode, max_examples, lm)
      end)

    report = %{
      "schema_version" => 1,
      "mode" => Atom.to_string(mode),
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "tasks" => task_results,
      "aggregate_score" => average(Enum.map(task_results, & &1["score"]))
    }

    out_path =
      Path.join(out_dir, "benchmark-truth-#{report["mode"]}-#{timestamp_slug()}.json")

    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")
    %{report: report, out_path: out_path}
  end

  defp run_task(task, path, mode, max_examples, lm) do
    examples =
      task
      |> load_examples(path)
      |> Enum.take(max_examples)

    effective_lm = lm || fixture_lm(task, examples)
    program = program(task, effective_lm)
    metric = metric(task)
    evaluator = DSEx.Evaluate.new(examples, metric, max_errors: :infinity)
    result = DSEx.Evaluate.run(evaluator, program)
    optimizer_comparisons = optimizer_comparisons(task, examples, effective_lm, metric)

    %{
      "task" => Atom.to_string(task),
      "path" => path,
      "sha256" => file_sha256(path),
      "mode" => Atom.to_string(mode),
      "examples" => length(examples),
      "score" => result.score,
      "optimizer_comparisons" => optimizer_comparisons,
      "errors" => Enum.map(result.errors, &safe_json/1),
      "rows" => Enum.map(result.rows, &row_summary/1)
    }
  end

  defp load_examples(:gsm8k, path), do: DSEx.Datasets.GSM8K.load(path)
  defp load_examples(:hotpotqa, path), do: DSEx.Datasets.HotPotQA.load(path)

  defp program(:gsm8k, lm) do
    "question -> answer"
    |> DSEx.signature(
      "Solve the math word problem. Return only the final numeric answer in `answer`."
    )
    |> DSEx.chain_of_thought(lm: lm, adapter: DSEx.Adapter.JSON, config: [json_retries: 1])
  end

  defp program(:hotpotqa, lm) do
    "question, context -> answer"
    |> DSEx.signature(
      "Answer using the provided context. Return the shortest exact answer string."
    )
    |> DSEx.predict(lm: lm, adapter: DSEx.Adapter.JSON, config: [json_retries: 1])
  end

  defp metric(:gsm8k) do
    fn example, prediction ->
      gold = DSEx.Example.get(example, :canonical_answer, DSEx.Example.get(example, :answer))
      predicted = DSEx.Prediction.get(prediction, :answer)
      DSEx.Metrics.normalize_text(predicted) == DSEx.Metrics.normalize_text(gold)
    end
  end

  defp metric(:hotpotqa) do
    fn example, prediction ->
      DSEx.Metrics.em(
        DSEx.Prediction.get(prediction, :answer),
        DSEx.Example.get(example, :answer)
      )
    end
  end

  defp optimizer_comparisons(_task, examples, _lm, _metric) when length(examples) < 2, do: []

  defp optimizer_comparisons(task, examples, lm, metric) do
    {trainset, devset} = Enum.split(examples, max(1, div(length(examples), 2)))
    baseline = program(task, lm)
    evaluator = DSEx.Evaluate.new(devset, metric, max_errors: :infinity)
    baseline_result = DSEx.Evaluate.run(evaluator, baseline)

    Enum.map(optimizer_specs(metric, trainset), fn {name, compile_fun} ->
      compare_optimizer(name, compile_fun, baseline, trainset, devset, evaluator, baseline_result)
    end)
  end

  defp optimizer_specs(metric, trainset) do
    k = min(2, length(trainset))

    [
      {"LabeledFewShot",
       fn program, trainset, _devset ->
         DSEx.Optimizer.LabeledFewShot.new(k: k)
         |> DSEx.Optimizer.LabeledFewShot.compile(program, trainset)
       end},
      {"BootstrapFewShot",
       fn program, trainset, _devset ->
         DSEx.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: k)
         |> DSEx.Optimizer.BootstrapFewShot.compile(program, trainset)
       end},
      {"COPRO",
       fn program, trainset, devset ->
         DSEx.Optimizer.COPRO.new(metric, breadth: 2, depth: 1)
         |> DSEx.Optimizer.COPRO.compile(program, trainset, devset)
       end},
      {"MIPROv2",
       fn program, trainset, devset ->
         DSEx.Optimizer.MIPROv2.new(metric, trials: 2, demos_per_candidate: k, cold_start: 1)
         |> DSEx.Optimizer.MIPROv2.compile(program, trainset, devset)
       end},
      {"SIMBA",
       fn program, trainset, devset ->
         DSEx.Optimizer.SIMBA.new(metric, steps: 1, demos_per_step: k)
         |> DSEx.Optimizer.SIMBA.compile(program, trainset, devset)
       end},
      {"GEPA",
       fn program, trainset, devset ->
         DSEx.Optimizer.GEPA.new(metric, generations: 1)
         |> DSEx.Optimizer.GEPA.compile(program, trainset, devset)
       end}
    ]
  end

  defp compare_optimizer(
         name,
         compile_fun,
         baseline,
         trainset,
         devset,
         evaluator,
         baseline_result
       ) do
    optimized = compile_fun.(baseline, trainset, devset)
    optimized_result = DSEx.Evaluate.run(evaluator, optimized)

    %{
      "optimizer" => name,
      "train_examples" => length(trainset),
      "dev_examples" => length(devset),
      "baseline_score" => baseline_result.score,
      "optimized_score" => optimized_result.score,
      "delta" => optimized_result.score - baseline_result.score,
      "status" => "ok"
    }
  rescue
    error ->
      %{
        "optimizer" => name,
        "train_examples" => length(trainset),
        "dev_examples" => length(devset),
        "baseline_score" => baseline_result.score,
        "optimized_score" => nil,
        "delta" => nil,
        "status" => "error",
        "error" => Exception.message(error)
      }
  end

  defp fixture_lm(task, examples) do
    lookup =
      Map.new(examples, fn example ->
        {DSEx.Example.get(example, :question), fixture_fields(task, example)}
      end)

    %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          text = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))
          question = Enum.find(Map.keys(lookup), &String.contains?(text, &1))
          Map.get(lookup, question, %{answer: ""})
        end
      ]
    }
  end

  defp fixture_fields(:gsm8k, example) do
    %{
      reasoning: "Use the canonical GSM8K answer extracted from the benchmark row.",
      answer: DSEx.Example.get(example, :canonical_answer, DSEx.Example.get(example, :answer))
    }
  end

  defp fixture_fields(:hotpotqa, example), do: %{answer: DSEx.Example.get(example, :answer)}

  defp row_summary(row) do
    %{
      "index" => row.index,
      "score" => row.score,
      "passed" => row.passed?,
      "prediction" => prediction_summary(row.prediction),
      "error" => safe_json(row.error)
    }
  end

  defp prediction_summary(nil), do: nil
  defp prediction_summary(%DSEx.Prediction{} = prediction), do: DSEx.Prediction.to_map(prediction)

  defp safe_json(nil), do: nil
  defp safe_json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp safe_json(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_json(value) when is_list(value), do: Enum.map(value, &safe_json/1)

  defp safe_json(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), safe_json(v)} end)

  defp safe_json(value), do: inspect(value)

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp file_sha256(path), do: path |> File.read!() |> sha256()
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

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
end
