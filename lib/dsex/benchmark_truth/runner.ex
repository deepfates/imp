defmodule DSEx.BenchmarkTruth.Runner do
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

    effective_lm = lm || fixture_lm(task, examples)
    program = program(task, effective_lm)
    metric = metric(task)
    {duration_us, result} = timed(fn -> evaluate(program, examples, metric, max_concurrency) end)

    optimizer_comparisons =
      if optimizer_comparisons?,
        do: optimizer_comparisons(task, examples, effective_lm, metric),
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

  defp load_examples(:gsm8k, path), do: DSEx.Datasets.GSM8K.load(path)
  defp load_examples(:hotpotqa, path), do: DSEx.Datasets.HotPotQA.load(path)
  defp load_examples(:colors, path), do: DSEx.Datasets.jsonl(path, [:input])

  defp load_examples(task, path) when task in [:iris, :iris_typo, :heart_disease],
    do: DSEx.Datasets.jsonl(path, [:features])

  defp program(:gsm8k, lm) do
    "question -> answer: string \"final numeric answer\""
    |> DSEx.signature(
      "Solve the math word problem. Return only the final numeric answer in `answer`."
    )
    |> DSEx.chain_of_thought(lm: lm, adapter: DSEx.Adapter.Chat)
  end

  defp program(:hotpotqa, lm) do
    "question, context -> answer: string \"short exact answer\""
    |> DSEx.signature(DSEx.BenchmarkTruth.Contract.hotpotqa_instruction())
    |> DSEx.predict(lm: lm, adapter: DSEx.Adapter.Chat)
  end

  defp program(:colors, lm) do
    "input -> label: string \"class label\""
    |> DSEx.signature("Classify the color into the correct label.")
    |> DSEx.predict(lm: lm, adapter: DSEx.Adapter.Chat)
  end

  defp program(task, lm) when task in [:iris, :iris_typo, :heart_disease] do
    "features -> label: string \"class label\""
    |> DSEx.signature("Classify the tabular feature row into the correct label.")
    |> DSEx.predict(lm: lm, adapter: DSEx.Adapter.Chat)
  end

  defp metric(:gsm8k) do
    fn example, prediction ->
      gold = DSEx.Example.get(example, :canonical_answer, DSEx.Example.get(example, :answer))
      predicted = DSEx.Prediction.get(prediction, :answer)

      numeric_answer_equal?(predicted, gold) ||
        DSEx.Metrics.normalize_text(predicted) == DSEx.Metrics.normalize_text(gold)
    end
  end

  defp metric(:hotpotqa) do
    fn example, prediction ->
      predicted = DSEx.Prediction.get(prediction, :answer)
      gold = DSEx.Example.get(example, :answer)
      result = DSEx.Metrics.extractive_qa(predicted, gold, metric_name: "hotpotqa_exact_match")

      metadata =
        result.metadata
        |> Map.put("official_hotpotqa_f1", result.metadata["f1"])
        |> Map.put("official_hotpotqa_em", result.metadata["exact_match"])

      %{result | metadata: metadata}
    end
  end

  defp metric(task) when task in [:colors, :iris, :iris_typo, :heart_disease] do
    fn example, prediction ->
      predicted = DSEx.Prediction.get(prediction, :label)
      gold = DSEx.Example.get(example, :label)
      DSEx.Metrics.classification(predicted, gold, metric_name: "#{task}_label_accuracy")
    end
  end

  defp aggregate_metrics(task, rows) when task in [:colors, :iris, :iris_typo, :heart_disease] do
    pairs =
      Enum.map(rows, fn row ->
        %{
          gold: DSEx.Example.get(row.example, :label),
          predicted: row.prediction && DSEx.Prediction.get(row.prediction, :label)
        }
      end)

    DSEx.Metrics.classification_report(pairs, metric_name: "#{task}_classification_report")
  end

  defp aggregate_metrics(_task, _rows), do: %{}

  defp evaluate(program, examples, metric, max_concurrency) when max_concurrency <= 1 do
    {rows, errors} =
      examples
      |> Enum.with_index()
      |> Enum.map(fn {example, index} -> evaluate_row(program, example, metric, index) end)
      |> Enum.unzip()

    errors = Enum.reject(errors, &is_nil/1)

    %DSEx.Evaluate.Result{
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

    %DSEx.Evaluate.Result{
      score: average(Enum.map(rows, & &1.score)),
      rows: rows,
      errors: errors
    }
  end

  defp evaluate_row(program, example, metric, index) do
    inputs = example |> DSEx.Example.inputs() |> DSEx.Example.to_map()

    {duration_us, {outcome, instrumentation}} =
      timed(fn ->
        collect_instrumentation(fn ->
          with {:ok, prediction} <- DSEx.Module.call(program, inputs) do
            result =
              metric
              |> apply_metric(example, prediction)
              |> DSEx.Metrics.normalize_result()

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
      [:dsex, :lm, :stop],
      [:dsex, :adapter, :parse, :json_fallback],
      [:dsex, :adapter, :parse, :retry]
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
      "json_fallbacks" => 0,
      "parse_retries" => 0
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

  defp update_instrumentation(stats, [:dsex, :lm, :stop], measurements) do
    duration_ms =
      measurements
      |> Map.get(:duration, 0)
      |> System.convert_time_unit(:native, :microsecond)
      |> us_to_ms()

    stats
    |> Map.update!("lm_calls", &(&1 + 1))
    |> Map.update!("lm_duration_ms", &Float.round(&1 + duration_ms, 3))
  end

  defp update_instrumentation(stats, [:dsex, :adapter, :parse, :json_fallback], _measurements),
    do: Map.update!(stats, "json_fallbacks", &(&1 + 1))

  defp update_instrumentation(stats, [:dsex, :adapter, :parse, :retry], _measurements),
    do: Map.update!(stats, "parse_retries", &(&1 + 1))

  defp update_instrumentation(stats, _event, _measurements), do: stats

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
    {compile_duration_us, optimized} = timed(fn -> compile_fun.(baseline, trainset, devset) end)

    {eval_duration_us, optimized_result} =
      timed(fn -> DSEx.Evaluate.run(evaluator, optimized) end)

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
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          text = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))

          key =
            lookup
            |> Map.keys()
            |> Enum.map(&{&1, fixture_key_last_position(text, &1)})
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
       do: to_string(DSEx.Example.get(example, :input, DSEx.Example.get(example, :features)))

  defp fixture_lookup_key(_task, example), do: DSEx.Example.get(example, :question)

  defp fixture_fields(:gsm8k, example) do
    %{
      reasoning: "Use the canonical GSM8K answer extracted from the benchmark row.",
      answer: DSEx.Example.get(example, :canonical_answer, DSEx.Example.get(example, :answer))
    }
  end

  defp fixture_fields(:hotpotqa, example), do: %{answer: DSEx.Example.get(example, :answer)}

  defp fixture_fields(task, example) when task in [:colors, :iris, :iris_typo, :heart_disease],
    do: %{label: DSEx.Example.get(example, :label)}

  defp fixture_empty_fields(task) when task in [:colors, :iris, :iris_typo, :heart_disease],
    do: %{label: ""}

  defp fixture_empty_fields(_task), do: %{answer: ""}

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
  defp prediction_summary(%DSEx.Prediction{} = prediction), do: DSEx.Prediction.to_map(prediction)

  defp row_diagnostic(row) do
    example = DSEx.Example.to_map(row.example)
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

  defp raw_prediction_trace(%DSEx.Prediction{metadata: %{trace: trace}}), do: trace
  defp raw_prediction_trace(%DSEx.Prediction{metadata: %{"trace" => trace}}), do: trace
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

  defp prediction_trace(%DSEx.Prediction{metadata: %{trace: trace}}), do: compact_trace(trace)
  defp prediction_trace(%DSEx.Prediction{metadata: %{"trace" => trace}}), do: compact_trace(trace)
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
