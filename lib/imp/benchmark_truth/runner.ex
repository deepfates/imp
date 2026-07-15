defmodule Imp.BenchmarkTruth.Runner do
  @moduledoc false

  @default_out_dir "benchmarks/results"

  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :fixture)
    tasks = Keyword.fetch!(opts, :tasks)
    out_dir = Keyword.get(opts, :out_dir, @default_out_dir)
    offset = Keyword.get(opts, :offset, 0)
    max_examples = Keyword.get(opts, :max_examples, 20)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    lm = Keyword.get(opts, :lm)
    model = Keyword.get(opts, :model)
    generation = Keyword.get(opts, :generation, %{})
    campaign_id = Keyword.get(opts, :campaign_id)
    optimizer_comparisons? = Keyword.get(opts, :optimizer_comparisons, true)

    File.mkdir_p!(out_dir)

    task_results =
      tasks
      |> Enum.map(fn {task, path} ->
        run_task(
          task,
          path,
          mode,
          offset,
          max_examples,
          max_concurrency,
          lm,
          model,
          optimizer_comparisons?
        )
      end)

    report = %{
      "schema_version" => 1,
      "mode" => Atom.to_string(mode),
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "campaign_id" => campaign_id,
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "model" => safe_json(model),
      "generation" => safe_json(generation),
      "tasks" => task_results,
      "aggregate_score" => average(Enum.map(task_results, & &1["score"]))
    }

    out_path =
      Path.join(out_dir, "benchmark-truth-#{report["mode"]}-#{timestamp_slug()}.json")

    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")
    %{report: report, out_path: out_path}
  end

  defp run_task(
         task,
         path,
         mode,
         offset,
         max_examples,
         max_concurrency,
         lm,
         model,
         optimizer_comparisons?
       ) do
    examples =
      task
      |> load_examples(path)
      |> Enum.drop(offset)
      |> Enum.take(max_examples)

    if task == :composition_orchestration do
      run_composition_task(path, mode, offset, max_concurrency, model, examples)
    else
      run_program_task(
        task,
        path,
        mode,
        offset,
        max_examples,
        max_concurrency,
        lm,
        model,
        optimizer_comparisons?,
        examples
      )
    end
  end

  defp run_program_task(
         task,
         path,
         mode,
         offset,
         _max_examples,
         max_concurrency,
         lm,
         model,
         optimizer_comparisons?,
         examples
       ) do
    effective_lm = lm || fixture_lm(task, examples)
    program = program(task, effective_lm, path)
    metric = metric(task)
    {duration_us, result} = timed(fn -> evaluate(program, examples, metric, max_concurrency) end)

    optimizer_comparisons =
      if optimizer_comparisons?,
        do: optimizer_comparisons(task, examples, effective_lm, metric, path),
        else: []

    %{
      "task" => Atom.to_string(task),
      "path" => path,
      "sha256" => file_sha256(path),
      "mode" => Atom.to_string(mode),
      "model" => safe_json(model),
      "offset" => offset,
      "examples" => length(examples),
      "max_concurrency" => max_concurrency,
      "score" => result.score,
      "duration_ms" => us_to_ms(duration_us),
      "optimizer_comparisons" => optimizer_comparisons,
      "aggregate_metrics" => aggregate_metrics(task, result.rows),
      "errors" => Enum.map(result.errors, &safe_json/1),
      "rows" => Enum.map(result.rows, &row_summary/1)
    }
  end

  defp run_composition_task(path, mode, offset, max_concurrency, model, examples) do
    {duration_us, result} =
      timed(fn ->
        Imp.BenchmarkTruth.Composition.run(examples, max_concurrency: max_concurrency)
      end)

    %{
      "task" => "composition_orchestration",
      "path" => path,
      "sha256" => file_sha256(path),
      "mode" => Atom.to_string(mode),
      "model" => safe_json(model),
      "offset" => offset,
      "examples" => length(examples),
      "max_concurrency" => max_concurrency,
      "score" => result["score"],
      "duration_ms" => us_to_ms(duration_us),
      "optimizer_comparisons" => [],
      "aggregate_metrics" => result["aggregate_metrics"],
      "errors" => [],
      "rows" => [],
      "scenarios" => result["scenarios"]
    }
  end

  defp load_examples(:gsm8k, path), do: Imp.Datasets.GSM8K.load(path)
  defp load_examples(:hotpotqa, path), do: Imp.Datasets.HotPotQA.load(path)
  defp load_examples(:colors, path), do: Imp.Datasets.jsonl(path, [:input])
  defp load_examples(:retrieval_qa, path), do: Imp.Datasets.jsonl(path, [:question])
  defp load_examples(:claim_verification, path), do: Imp.Datasets.jsonl(path, [:claim])
  defp load_examples(:composition_orchestration, path), do: Imp.Datasets.jsonl(path, [:question])

  defp load_examples(:ifbench_instruction_following, path),
    do: Imp.Datasets.jsonl(path, [:instruction])

  defp load_examples(:hard_math, path), do: Imp.Datasets.jsonl(path, [:problem])

  defp load_examples(task, path) when task in [:iris, :iris_typo, :heart_disease],
    do: Imp.Datasets.jsonl(path, [:features])

  defp program(:gsm8k, lm, _path) do
    "question -> answer: string \"final numeric answer\""
    |> Imp.signature(
      "Solve the math word problem. Return only the final numeric answer in `answer`."
    )
    |> Imp.chain_of_thought(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp program(:hotpotqa, lm, _path) do
    "question, context -> answer: string \"short exact answer\""
    |> Imp.signature(Imp.BenchmarkTruth.Contract.hotpotqa_instruction())
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp program(:colors, lm, _path) do
    "input -> label: string \"class label\""
    |> Imp.signature("Classify the color into the correct label.")
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp program(task, lm, _path) when task in [:iris, :iris_typo, :heart_disease] do
    "features -> label: string \"class label\""
    |> Imp.signature("Classify the tabular feature row into the correct label.")
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp program(:retrieval_qa, lm, path) do
    base =
      "question, context -> answer: string \"short exact answer\""
      |> Imp.signature("Answer using only the retrieved context.")
      |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)

    Imp.rag(base, memory_retriever(path), k: 2)
  end

  defp program(:claim_verification, lm, path) do
    base =
      "claim, context -> label: string \"supported or refuted\""
      |> Imp.signature("Verify the claim using only the retrieved context.")
      |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)

    Imp.rag(base, memory_retriever(path), query_field: :claim, k: 2)
  end

  defp program(:ifbench_instruction_following, lm, _path) do
    "instruction -> answer: string \"constraint-satisfying response\""
    |> Imp.signature("Follow the instruction exactly. Return only the requested answer.")
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp program(:hard_math, lm, _path) do
    "problem -> answer: string \"final numeric or symbolic answer\""
    |> Imp.signature("Solve the hard math problem. Return only the final answer.")
    |> Imp.chain_of_thought(lm: lm, adapter: Imp.Adapter.Chat)
  end

  defp metric(:gsm8k) do
    fn example, prediction ->
      gold = Imp.Example.get(example, :canonical_answer, Imp.Example.get(example, :answer))
      predicted = Imp.Prediction.get(prediction, :answer)

      numeric_answer_equal?(predicted, gold) ||
        Imp.Metrics.normalize_text(predicted) == Imp.Metrics.normalize_text(gold)
    end
  end

  defp metric(:hotpotqa) do
    fn example, prediction ->
      predicted = Imp.Prediction.get(prediction, :answer)
      gold = Imp.Example.get(example, :answer)
      result = Imp.Metrics.extractive_qa(predicted, gold, metric_name: "hotpotqa_exact_match")

      metadata =
        result.metadata
        |> Map.put("official_hotpotqa_f1", result.metadata["f1"])
        |> Map.put("official_hotpotqa_em", result.metadata["exact_match"])

      %{result | metadata: metadata}
    end
  end

  defp metric(task) when task in [:colors, :iris, :iris_typo, :heart_disease] do
    fn example, prediction ->
      predicted = Imp.Prediction.get(prediction, :label)
      gold = Imp.Example.get(example, :label)
      Imp.Metrics.classification(predicted, gold, metric_name: "#{task}_label_accuracy")
    end
  end

  defp metric(:retrieval_qa) do
    fn example, prediction ->
      answer =
        prediction
        |> Imp.Prediction.get(:answer)

      answer_result =
        answer
        |> Imp.Metrics.extractive_qa(Imp.Example.get(example, :answer),
          metric_name: "retrieval_qa_answer"
        )

      recall_result =
        prediction
        |> Imp.Metrics.retrieval_recall(Imp.Example.get(example, :evidence_ids),
          metric_name: "retrieval_qa_evidence_recall"
        )

      combine_metric_results(answer_result, recall_result)
    end
  end

  defp metric(:claim_verification) do
    fn example, prediction ->
      label_result =
        Imp.Metrics.classification(
          Imp.Prediction.get(prediction, :label),
          Imp.Example.get(example, :label),
          metric_name: "claim_verification_label"
        )

      recall_result =
        prediction
        |> Imp.Metrics.retrieval_recall(Imp.Example.get(example, :evidence_ids),
          metric_name: "claim_verification_evidence_recall"
        )

      combine_metric_results(label_result, recall_result)
    end
  end

  defp metric(:ifbench_instruction_following) do
    fn example, prediction ->
      predicted = Imp.Prediction.get(prediction, :answer)
      constraints = Imp.Example.get(example, :constraints, [])
      constraint_results = Enum.map(constraints, &verify_constraint(predicted, &1))
      passed? = constraint_results != [] and Enum.all?(constraint_results, & &1.passed?)

      score =
        if constraint_results == [],
          do: 0.0,
          else: average(Enum.map(constraint_results, & &1.score))

      %Imp.Metrics.Result{
        score: score,
        passed?: passed?,
        metadata: %{
          "task_metric" => "ifbench_constraint_satisfaction",
          "constraint_count" => length(constraint_results),
          "satisfied_constraints" => Enum.count(constraint_results, & &1.passed?),
          "constraints" => Enum.map(constraint_results, & &1.metadata)
        }
      }
    end
  end

  defp metric(:hard_math) do
    fn example, prediction ->
      predicted = Imp.Prediction.get(prediction, :answer)
      gold = Imp.Example.get(example, :canonical_answer, Imp.Example.get(example, :answer))

      exact? =
        numeric_answer_equal?(predicted, gold) ||
          normalized_answer(predicted) == normalized_answer(gold)

      %Imp.Metrics.Result{
        score: if(exact?, do: 1.0, else: 0.0),
        passed?: exact?,
        metadata: %{
          "task_metric" => "hard_math_normalized_exact_match",
          "predicted_normalized" => normalized_answer(predicted),
          "gold_normalized" => normalized_answer(gold),
          "numeric_equivalent" => numeric_answer_equal?(predicted, gold)
        }
      }
    end
  end

  defp aggregate_metrics(task, rows) when task in [:colors, :iris, :iris_typo, :heart_disease] do
    pairs =
      Enum.map(rows, fn row ->
        %{
          gold: Imp.Example.get(row.example, :label),
          predicted: row.prediction && Imp.Prediction.get(row.prediction, :label)
        }
      end)

    Imp.Metrics.classification_report(pairs, metric_name: "#{task}_classification_report")
  end

  defp aggregate_metrics(task, rows) when task in [:retrieval_qa, :claim_verification] do
    recalls =
      rows
      |> Enum.map(&get_in(&1.metric_metadata, ["retrieval", "recall"]))
      |> Enum.reject(&is_nil/1)

    %{
      "task_metric" => "#{task}_retrieval_report",
      "examples" => length(rows),
      "mean_retrieval_recall" => average(recalls),
      "full_retrieval_recall_rows" => Enum.count(recalls, &(&1 >= 1.0))
    }
  end

  defp aggregate_metrics(:ifbench_instruction_following, rows) do
    scores = Enum.map(rows, & &1.score)

    %{
      "task_metric" => "ifbench_constraint_report",
      "examples" => length(rows),
      "mean_constraint_score" => average(scores),
      "full_constraint_rows" => Enum.count(rows, & &1.passed?)
    }
  end

  defp aggregate_metrics(:hard_math, rows) do
    %{
      "task_metric" => "hard_math_exact_report",
      "examples" => length(rows),
      "accuracy" => average(Enum.map(rows, & &1.score)),
      "exact_rows" => Enum.count(rows, & &1.passed?)
    }
  end

  defp aggregate_metrics(_task, _rows), do: %{}

  defp combine_metric_results(primary, retrieval) do
    score = (primary.score + retrieval.score) / 2

    %Imp.Metrics.Result{
      score: score,
      passed?: primary.passed? and retrieval.passed?,
      metadata: %{
        "task_metric" => "answer_or_label_plus_retrieval",
        "primary" => primary.metadata,
        "retrieval" => retrieval.metadata
      }
    }
  end

  defp evaluate(program, examples, metric, max_concurrency) when max_concurrency <= 1 do
    {rows, errors} =
      examples
      |> Enum.with_index()
      |> Enum.map(fn {example, index} -> evaluate_row(program, example, metric, index) end)
      |> Enum.unzip()

    errors = Enum.reject(errors, &is_nil/1)

    %Imp.Evaluate.Result{
      score: average(Enum.map(rows, & &1.score)),
      rows: rows,
      errors: errors
    }
  end

  defp evaluate(program, examples, metric, max_concurrency) do
    {rows, errors} =
      examples
      |> Enum.with_index()
      |> Task.async_stream(
        fn {example, index} -> evaluate_row(program, example, metric, index) end,
        max_concurrency: max_concurrency,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, value} -> value end)
      |> Enum.unzip()

    errors = Enum.reject(errors, &is_nil/1)

    %Imp.Evaluate.Result{
      score: average(Enum.map(rows, & &1.score)),
      rows: rows,
      errors: errors
    }
  end

  defp evaluate_row(program, example, metric, index) do
    inputs = example |> Imp.Example.inputs() |> Imp.Example.to_map()

    {duration_us, {outcome, instrumentation}} =
      timed(fn ->
        collect_instrumentation(fn ->
          with {:ok, prediction} <- Imp.Module.call(program, inputs) do
            result =
              metric
              |> apply_metric(example, prediction)
              |> Imp.Metrics.normalize_result()

            {:ok, prediction, result}
          end
        end)
      end)

    row =
      case outcome do
        {:ok, prediction, result} ->
          %{
            index: index,
            example: example,
            prediction: prediction,
            score: result.score,
            passed?: result.passed?,
            feedback: result.feedback,
            metric_metadata: result.metadata,
            error: nil,
            duration_us: duration_us,
            instrumentation: instrumentation
          }

        {:error, reason} ->
          %{
            index: index,
            example: example,
            prediction: nil,
            score: 0.0,
            passed?: false,
            feedback: nil,
            metric_metadata: %{},
            error: reason,
            duration_us: duration_us,
            instrumentation: instrumentation
          }
      end

    error = if row.error, do: %{index: index, reason: row.error}, else: nil
    {row, error}
  end

  defp collect_instrumentation(fun) do
    key = {__MODULE__, self(), make_ref()}
    Process.put(key, empty_instrumentation())

    events = [
      [:imp, :lm, :stop],
      [:imp, :adapter, :parse, :json_fallback],
      [:imp, :adapter, :parse, :retry],
      [:req_llm, :request, :stop],
      [:req_llm, :request, :exception],
      [:finch, :request, :stop],
      [:finch, :request, :exception],
      [:finch, :queue, :stop],
      [:finch, :queue, :exception],
      [:finch, :connect, :stop],
      [:finch, :send, :stop],
      [:finch, :recv, :stop],
      [:finch, :recv, :exception],
      [:req_llm, :token_usage]
    ]

    :telemetry.attach_many(key, events, &__MODULE__.record_instrumentation/4, {self(), key})

    try do
      {fun.(), Process.get(key, empty_instrumentation())}
    after
      :telemetry.detach(key)
      Process.delete(key)
    end
  end

  defp empty_instrumentation do
    %{
      "lm_calls" => 0,
      "lm_duration_ms" => 0.0,
      "req_llm_requests" => 0,
      "req_llm_request_duration_ms" => 0.0,
      "finch_requests" => 0,
      "finch_request_duration_ms" => 0.0,
      "finch_queue_events" => 0,
      "finch_queue_duration_ms" => 0.0,
      "finch_connects" => 0,
      "finch_connect_duration_ms" => 0.0,
      "finch_sends" => 0,
      "finch_send_duration_ms" => 0.0,
      "finch_receives" => 0,
      "finch_receive_duration_ms" => 0.0,
      "json_fallbacks" => 0,
      "parse_retries" => 0,
      "usage_events" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "usd" => 0.0
    }
  end

  @doc false
  def record_instrumentation(event, measurements, _metadata, {owner, key}) do
    if self() == owner do
      Process.put(
        key,
        update_instrumentation(Process.get(key, empty_instrumentation()), event, measurements)
      )
    end
  end

  defp update_instrumentation(stats, [:imp, :lm, :stop], measurements) do
    duration_ms =
      measurements
      |> Map.get(:duration, 0)
      |> System.convert_time_unit(:native, :microsecond)
      |> us_to_ms()

    stats
    |> Map.update!("lm_calls", &(&1 + 1))
    |> Map.update!("lm_duration_ms", &Float.round(&1 + duration_ms, 3))
  end

  defp update_instrumentation(stats, [:imp, :adapter, :parse, :json_fallback], _measurements),
    do: Map.update!(stats, "json_fallbacks", &(&1 + 1))

  defp update_instrumentation(stats, [:imp, :adapter, :parse, :retry], _measurements),
    do: Map.update!(stats, "parse_retries", &(&1 + 1))

  defp update_instrumentation(stats, [:req_llm, :request, outcome], measurements)
       when outcome in [:stop, :exception],
       do: add_timing(stats, "req_llm_requests", "req_llm_request_duration_ms", measurements)

  defp update_instrumentation(stats, [:finch, :request, outcome], measurements)
       when outcome in [:stop, :exception],
       do: add_timing(stats, "finch_requests", "finch_request_duration_ms", measurements)

  defp update_instrumentation(stats, [:finch, :queue, outcome], measurements)
       when outcome in [:stop, :exception],
       do: add_timing(stats, "finch_queue_events", "finch_queue_duration_ms", measurements)

  defp update_instrumentation(stats, [:finch, :connect, :stop], measurements),
    do: add_timing(stats, "finch_connects", "finch_connect_duration_ms", measurements)

  defp update_instrumentation(stats, [:finch, :send, :stop], measurements),
    do: add_timing(stats, "finch_sends", "finch_send_duration_ms", measurements)

  defp update_instrumentation(stats, [:finch, :recv, outcome], measurements)
       when outcome in [:stop, :exception],
       do: add_timing(stats, "finch_receives", "finch_receive_duration_ms", measurements)

  defp update_instrumentation(stats, [:req_llm, :token_usage], measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    stats
    |> Map.update!("usage_events", &(&1 + 1))
    |> Map.update!("input_tokens", &(&1 + trunc(first_number(tokens, [:input_tokens, :input]))))
    |> Map.update!(
      "output_tokens",
      &(&1 + trunc(first_number(tokens, [:output_tokens, :output])))
    )
    |> Map.update!("usd", &(&1 + first_number(measurements, [:total_cost, :cost])))
  end

  defp update_instrumentation(stats, _event, _measurements), do: stats

  defp add_timing(stats, count_key, duration_key, measurements) do
    duration_ms =
      measurements
      |> Map.get(:duration, 0)
      |> System.convert_time_unit(:native, :microsecond)
      |> us_to_ms()

    stats
    |> Map.update!(count_key, &(&1 + 1))
    |> Map.update!(duration_key, &Float.round(&1 + duration_ms, 3))
  end

  defp first_number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value), do: value
    end)
  end

  defp apply_metric(metric, example, prediction) when is_function(metric, 2),
    do: metric.(example, prediction)

  defp apply_metric(metric, example, prediction) when is_function(metric, 3),
    do: metric.(example, prediction, nil)

  defp numeric_answer_equal?(predicted, gold) do
    with {:ok, predicted_number} <- parse_numeric_answer(predicted),
         {:ok, gold_number} <- parse_numeric_answer(gold) do
      abs(predicted_number - gold_number) <= 1.0e-9
    else
      _other -> false
    end
  end

  defp parse_numeric_answer(value) do
    text =
      value
      |> to_string()
      |> String.trim()
      |> String.replace(",", "")
      |> String.trim_leading("$")

    if String.match?(text, ~r/^-?\d+(?:\.\d+)?$/) do
      case Float.parse(text) do
        {number, ""} -> {:ok, number}
        _other -> :error
      end
    else
      :error
    end
  end

  defp normalized_answer(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.trim(".")
    |> String.downcase()
  end

  defp verify_constraint(answer, %{"type" => "exact", "value" => value}) do
    passed? = Imp.Metrics.normalize_text(answer) == Imp.Metrics.normalize_text(value)
    constraint_result("exact", passed?, %{"value" => value})
  end

  defp verify_constraint(answer, %{"type" => "contains", "value" => value}) do
    passed? =
      String.contains?(String.downcase(to_string(answer)), String.downcase(to_string(value)))

    constraint_result("contains", passed?, %{"value" => value})
  end

  defp verify_constraint(answer, %{"type" => "forbid", "value" => value}) do
    passed? =
      not String.contains?(String.downcase(to_string(answer)), String.downcase(to_string(value)))

    constraint_result("forbid", passed?, %{"value" => value})
  end

  defp verify_constraint(answer, %{"type" => "max_words", "value" => max_words}) do
    words = answer |> Imp.Metrics.normalize_text() |> String.split()
    passed? = length(words) <= max_words

    constraint_result("max_words", passed?, %{"value" => max_words, "word_count" => length(words)})
  end

  defp verify_constraint(_answer, constraint) do
    constraint_result("unknown", false, %{"constraint" => safe_json(constraint)})
  end

  defp constraint_result(type, passed?, metadata) do
    %Imp.Metrics.Result{
      score: if(passed?, do: 1.0, else: 0.0),
      passed?: passed?,
      metadata: Map.put(metadata, "type", type) |> Map.put("passed", passed?)
    }
  end

  defp optimizer_comparisons(_task, examples, _lm, _metric, _path) when length(examples) < 2,
    do: []

  defp optimizer_comparisons(task, examples, lm, metric, path) do
    {trainset, devset} = Enum.split(examples, max(1, div(length(examples), 2)))
    baseline = program(task, lm, path)
    evaluator = Imp.Evaluate.new(devset, metric, max_errors: :infinity)
    baseline_result = Imp.Evaluate.run(evaluator, baseline)

    Enum.map(optimizer_specs(metric, trainset), fn {name, compile_fun} ->
      compare_optimizer(name, compile_fun, baseline, trainset, devset, evaluator, baseline_result)
    end)
  end

  defp optimizer_specs(metric, trainset) do
    k = min(2, length(trainset))

    [
      {"LabeledFewShot",
       fn program, trainset, _devset ->
         Imp.Optimizer.LabeledFewShot.new(k: k)
         |> Imp.Optimizer.LabeledFewShot.compile(program, trainset)
       end},
      {"BootstrapFewShot",
       fn program, trainset, _devset ->
         Imp.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: k)
         |> Imp.Optimizer.BootstrapFewShot.compile(program, trainset)
       end},
      {"COPRO",
       fn program, trainset, devset ->
         Imp.Optimizer.COPRO.new(metric, breadth: 2, depth: 1)
         |> Imp.Optimizer.COPRO.compile(program, trainset, devset)
       end},
      {"MIPROv2",
       fn program, trainset, devset ->
         Imp.Optimizer.MIPROv2.new(metric,
           auto: nil,
           num_candidates: 2,
           num_trials: 2,
           max_bootstrapped_demos: 0,
           max_labeled_demos: k,
           minibatch: false,
           startup_trials: 1
         )
         |> Imp.Optimizer.MIPROv2.compile(program, trainset, devset)
       end},
      {"SIMBA",
       fn program, trainset, devset ->
         Imp.Optimizer.SIMBA.new(metric, max_steps: 1, max_demos: k)
         |> Imp.Optimizer.SIMBA.compile(program, trainset, devset)
       end},
      {"GEPA",
       fn program, trainset, devset ->
         Imp.Optimizer.GEPA.new(metric, generations: 1)
         |> Imp.Optimizer.GEPA.compile(program, trainset, devset)
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
    {compile_duration_us, optimized} = timed(fn -> compile_fun.(baseline, trainset, devset) end)

    {eval_duration_us, optimized_result} =
      timed(fn -> Imp.Evaluate.run(evaluator, optimized) end)

    %{
      "optimizer" => name,
      "train_examples" => length(trainset),
      "dev_examples" => length(devset),
      "baseline_score" => baseline_result.score,
      "optimized_score" => optimized_result.score,
      "delta" => optimized_result.score - baseline_result.score,
      "compile_duration_ms" => us_to_ms(compile_duration_us),
      "eval_duration_ms" => us_to_ms(eval_duration_us),
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
        {fixture_lookup_key(task, example), fixture_fields(task, example)}
      end)

    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          text = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))
          lookup_text = fixture_lookup_text(task, text)

          key =
            lookup
            |> Map.keys()
            |> Enum.map(&{&1, fixture_key_last_position(lookup_text, &1)})
            |> Enum.reject(fn {_key, position} -> is_nil(position) end)
            |> Enum.max_by(fn {key, position} -> {position, String.length(key)} end, fn ->
              {nil, nil}
            end)
            |> elem(0)

          Map.get(lookup, key, fixture_empty_fields(task))
        end
      ]
    }
  end

  defp fixture_lookup_text(task, text) do
    prompt_field(text, fixture_prompt_field(task)) || text
  end

  defp fixture_prompt_field(:colors), do: "input"
  defp fixture_prompt_field(task) when task in [:iris, :iris_typo, :heart_disease], do: "features"
  defp fixture_prompt_field(:retrieval_qa), do: "question"
  defp fixture_prompt_field(:claim_verification), do: "claim"
  defp fixture_prompt_field(:ifbench_instruction_following), do: "instruction"
  defp fixture_prompt_field(:hard_math), do: "problem"
  defp fixture_prompt_field(_task), do: "question"

  defp prompt_field(text, field) do
    pattern =
      ~r/\[\[ ## #{Regex.escape(field)} ## \]\]\s*(.*?)(?=\n\[\[ ## |\nRespond with|\z)/su

    case pattern |> Regex.scan(text) |> List.last() do
      [_full, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp fixture_key_last_position(text, key) do
    ~r/(^|[^[:alnum:]_])#{Regex.escape(key)}([^[:alnum:]_]|$)/iu
    |> Regex.scan(text, return: :index)
    |> List.last()
    |> case do
      [{position, _length} | _captures] -> position
      nil -> nil
    end
  end

  defp fixture_lookup_key(task, example)
       when task in [:colors, :iris, :iris_typo, :heart_disease],
       do: to_string(Imp.Example.get(example, :input, Imp.Example.get(example, :features)))

  defp fixture_lookup_key(:retrieval_qa, example), do: Imp.Example.get(example, :question)
  defp fixture_lookup_key(:claim_verification, example), do: Imp.Example.get(example, :claim)

  defp fixture_lookup_key(:ifbench_instruction_following, example),
    do: Imp.Example.get(example, :instruction)

  defp fixture_lookup_key(:hard_math, example), do: Imp.Example.get(example, :problem)
  defp fixture_lookup_key(_task, example), do: Imp.Example.get(example, :question)

  defp fixture_fields(:gsm8k, example) do
    %{
      reasoning: "Use the canonical GSM8K answer extracted from the benchmark row.",
      answer: Imp.Example.get(example, :canonical_answer, Imp.Example.get(example, :answer))
    }
  end

  defp fixture_fields(:hotpotqa, example), do: %{answer: Imp.Example.get(example, :answer)}

  defp fixture_fields(task, example) when task in [:colors, :iris, :iris_typo, :heart_disease],
    do: %{label: Imp.Example.get(example, :label)}

  defp fixture_fields(:retrieval_qa, example), do: %{answer: Imp.Example.get(example, :answer)}

  defp fixture_fields(:claim_verification, example),
    do: %{label: Imp.Example.get(example, :label)}

  defp fixture_fields(:ifbench_instruction_following, example),
    do: %{answer: Imp.Example.get(example, :answer)}

  defp fixture_fields(:hard_math, example) do
    %{
      reasoning: "Use the canonical answer from the benchmark row.",
      answer: Imp.Example.get(example, :canonical_answer, Imp.Example.get(example, :answer))
    }
  end

  defp fixture_empty_fields(task) when task in [:colors, :iris, :iris_typo, :heart_disease],
    do: %{label: ""}

  defp fixture_empty_fields(:claim_verification), do: %{label: ""}

  defp fixture_empty_fields(_task), do: %{answer: ""}

  defp memory_retriever(path) do
    path
    |> corpus_path_for()
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Enum.to_list()
    |> Imp.Retrieve.Memory.new(k: 2)
  end

  defp corpus_path_for(data_path) do
    manifest_path = String.replace_suffix(data_path, ".jsonl", ".manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    corpus_path = Map.fetch!(manifest, "corpus_path")

    if Path.type(corpus_path) == :absolute do
      corpus_path
    else
      Path.expand(corpus_path)
    end
  end

  defp row_summary(row) do
    instrumentation =
      row
      |> Map.get(:instrumentation, empty_instrumentation())
      |> Map.merge(trace_instrumentation(row))

    summary = %{
      "index" => row.index,
      "score" => row.score,
      "passed" => row.passed?,
      "prediction" => prediction_summary(row.prediction),
      "metric_metadata" => safe_json(row.metric_metadata || %{}),
      "error" => safe_json(row.error),
      "duration_ms" => us_to_ms(Map.get(row, :duration_us, 0)),
      "instrumentation" => safe_json(instrumentation)
    }

    if row.passed? do
      summary
    else
      Map.put(summary, "diagnostic", row_diagnostic(row))
    end
  end

  defp prediction_summary(nil), do: nil
  defp prediction_summary(%Imp.Prediction{} = prediction), do: Imp.Prediction.to_map(prediction)

  defp row_diagnostic(row) do
    example = Imp.Example.to_map(row.example)
    context = Map.get(example, :context) || Map.get(example, "context")

    %{
      "gold_answer" => Map.get(example, :answer) || Map.get(example, "answer"),
      "question" => Map.get(example, :question) || Map.get(example, "question"),
      "context_sha256" => text_sha256(context),
      "context_length" => context && String.length(to_string(context)),
      "trace" => row_trace(row)
    }
  end

  defp row_trace(row), do: prediction_trace(row.prediction) || error_trace(row.error)

  defp trace_instrumentation(row) do
    case raw_trace(row) do
      nil ->
        %{}

      %{messages: messages, raw: raw} ->
        %{
          "message_count" => length(messages || []),
          "message_chars" => message_chars(messages || []),
          "raw_chars" => raw_chars(raw)
        }

      %{"messages" => messages, "raw" => raw} ->
        %{
          "message_count" => length(messages || []),
          "message_chars" => message_chars(messages || []),
          "raw_chars" => raw_chars(raw)
        }
    end
  end

  defp raw_trace(row), do: raw_prediction_trace(row.prediction) || raw_error_trace(row.error)

  defp raw_prediction_trace(%Imp.Prediction{metadata: %{trace: trace}}), do: trace
  defp raw_prediction_trace(%Imp.Prediction{metadata: %{"trace" => trace}}), do: trace
  defp raw_prediction_trace(_prediction), do: nil

  defp raw_error_trace(%{trace: trace}), do: trace
  defp raw_error_trace(%{"trace" => trace}), do: trace
  defp raw_error_trace(_error), do: nil

  defp message_chars(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      content = Map.get(message, :content) || Map.get(message, "content") || ""
      acc + String.length(to_string(content))
    end)
  end

  defp raw_chars(raw) when is_binary(raw), do: String.length(raw)
  defp raw_chars(raw), do: raw |> safe_json() |> Jason.encode!() |> String.length()

  defp prediction_trace(%Imp.Prediction{metadata: %{trace: trace}}), do: compact_trace(trace)
  defp prediction_trace(%Imp.Prediction{metadata: %{"trace" => trace}}), do: compact_trace(trace)
  defp prediction_trace(_prediction), do: nil

  defp error_trace(%{trace: trace}), do: compact_trace(trace)
  defp error_trace(%{"trace" => trace}), do: compact_trace(trace)
  defp error_trace(_error), do: nil

  defp compact_trace(%{messages: messages, raw: raw}) do
    %{
      "messages" => Enum.map(messages, &compact_message/1),
      "raw" => truncate_middle(raw, 2_000)
    }
  end

  defp compact_trace(%{"messages" => messages, "raw" => raw}) do
    %{
      "messages" => Enum.map(messages, &compact_message/1),
      "raw" => truncate_middle(raw, 2_000)
    }
  end

  defp compact_trace(_trace), do: nil

  defp compact_message(message) do
    %{
      "role" => message[:role] || message["role"],
      "content" => truncate_middle(message[:content] || message["content"], 2_000)
    }
  end

  defp text_sha256(nil), do: nil

  defp text_sha256(text),
    do: :crypto.hash(:sha256, to_string(text)) |> Base.encode16(case: :lower)

  defp truncate_middle(nil, _limit), do: nil

  defp truncate_middle(value, limit) do
    text = if is_binary(value), do: value, else: inspect(value)

    if String.length(text) <= limit do
      text
    else
      keep = div(limit - 20, 2)
      String.slice(text, 0, keep) <> "\n...[truncated]...\n" <> String.slice(text, -keep, keep)
    end
  end

  defp safe_json(nil), do: nil
  defp safe_json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp safe_json(value) when is_atom(value), do: Atom.to_string(value)

  defp safe_json(value) when is_list(value) do
    if proper_list?(value), do: Enum.map(value, &safe_json/1), else: inspect(value)
  end

  defp safe_json(value) when is_tuple(value), do: value |> Tuple.to_list() |> safe_json()

  defp safe_json(%module{} = value),
    do:
      value
      |> Map.from_struct()
      |> Map.put(:__struct__, inspect(module))
      |> safe_json()

  defp safe_json(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), safe_json(v)} end)

  defp safe_json(value), do: inspect(value)

  defp proper_list?(value) when is_list(value), do: do_proper_list?(value)
  defp proper_list?(_value), do: false

  defp do_proper_list?([]), do: true
  defp do_proper_list?([_head | tail]), do: do_proper_list?(tail)
  defp do_proper_list?(_tail), do: false

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp timed(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - started, result}
  end

  defp us_to_ms(us), do: Float.round(us / 1000, 3)

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
