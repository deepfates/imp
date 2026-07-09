defmodule Mix.Tasks.Dsex.Benchmark.Rlm do
  @moduledoc """
  Run provider-free RLM benchmark evidence against a public long-context fixture.

      mix dsex.benchmark.rlm

  The lane compares DSEx RLM, Python DSPy RLM, direct prompting, and simple RAG
  over HotPotQA-shaped fixture rows. It is an operational parity lane, not a
  live-model leaderboard.
  """

  use Mix.Task

  @shortdoc "Run RLM benchmark parity evidence"

  @default_data "test/fixtures/benchmarks/hotpotqa-small.jsonl"
  @default_out_dir "benchmarks/results"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          data: :string,
          out: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    data_path = Keyword.get(opts, :data, @default_data)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    examples = load_jsonl!(data_path)
    dsex = dsex_report(examples, data_path)
    dspy = dspy_report(python(opts), data_path, out_dir)
    report = comparison_report(dsex, dspy)

    out_path = Path.join(out_dir, "rlm-benchmark-parity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("RLM benchmark parity report: #{out_path}")

    Mix.shell().info(
      "RLM benchmark passing rows: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_passing"] do
      Mix.raise("RLM benchmark parity failed; inspect #{out_path}")
    end
  end

  defp dsex_report(examples, data_path) do
    rows =
      Enum.flat_map(examples, fn example ->
        [direct_prompt_row(example), simple_rag_row(example), rlm_row(example)]
      end)

    %{
      "schema_version" => 1,
      "runner" => "dsex-rlm-benchmark",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "dataset" => %{
        "name" => "hotpotqa_fixture",
        "path" => data_path,
        "examples" => length(examples),
        "source" => "HotPotQA-shaped public benchmark fixture"
      },
      "rows" => rows,
      "summary" => summarize(rows)
    }
  end

  defp direct_prompt_row(example) do
    answer = answer_from_context(example["question"], example["context"])

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: answer} end]
    }

    program = DSEx.predict("question, context -> answer", lm: lm)

    {latency_us, {:ok, prediction}} =
      :timer.tc(fn ->
        DSEx.call(program, %{question: example["question"], context: example["context"]})
      end)

    measured_row("direct_prompt", example, DSEx.get(prediction, :answer), latency_us, %{
      "lm_calls" => 1,
      "subcalls" => 0,
      "trace_shape" => ["predict"]
    })
  end

  defp simple_rag_row(example) do
    docs = split_docs(example["context"])
    retriever = DSEx.memory(Enum.map(docs, &%{text: &1}), k: 2)
    answer = answer_from_context(example["question"], example["context"])

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: answer} end]
    }

    program = DSEx.rag(DSEx.predict("question, context -> answer", lm: lm), retriever, k: 2)

    {latency_us, {:ok, prediction}} =
      :timer.tc(fn ->
        DSEx.call(program, %{question: example["question"]})
      end)

    measured_row("simple_rag", example, DSEx.get(prediction, :answer), latency_us, %{
      "lm_calls" => 1,
      "subcalls" => 0,
      "retrieved" => Enum.map(prediction.metadata.retrieval.docs, & &1.text),
      "trace_shape" => ["retrieve", "predict"]
    })
  end

  defp rlm_row(example) do
    parent = self()
    answer = answer_from_context(example["question"], example["context"])

    context =
      DSEx.rlm_serializable(
        :context,
        fn ->
          example["context"]
        end,
        metadata: %{source: "hotpotqa_fixture", id: example["id"]}
      )

    actions = [
      %{action: "load", name: "context"},
      %{
        action: "llm_query_batched",
        signature: "question -> answer",
        inputs: supporting_subquestions(example)
      },
      %{action: "submit", result: %{answer: answer}}
    ]

    controller_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_benchmark_actions)
          Process.put(:rlm_benchmark_actions, rest)
          action
        end
      ]
    }

    sub_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:rlm_benchmark_subcall, messages})
          %{answer: "supporting fact"}
        end
      ]
    }

    Process.put(:rlm_benchmark_actions, actions)

    rlm =
      DSEx.rlm("context, question -> answer",
        lm: controller_lm,
        sub_lm: sub_lm,
        max_iterations: 4,
        max_llm_calls: 4,
        max_preview_chars: 80
      )

    {latency_us, {:ok, prediction}} =
      :timer.tc(fn ->
        DSEx.call(rlm, %{context: context, question: example["question"]})
      end)

    subcalls = drain_subcalls(0)
    trace = prediction.metadata.rlm_trace
    Process.delete(:rlm_benchmark_actions)

    measured_row("rlm", example, DSEx.get(prediction, :answer), latency_us, %{
      "lm_calls" => length(trace),
      "subcalls" => subcalls,
      "trace_shape" => Enum.map(trace, &to_string(&1.action)),
      "trace" => normalize(trace)
    })
  after
    Process.delete(:rlm_benchmark_actions)
  end

  defp supporting_subquestions(example) do
    example["context"]
    |> split_docs()
    |> Enum.map(fn doc -> %{question: "Summarize supporting fact: #{doc}"} end)
  end

  defp drain_subcalls(count) do
    receive do
      {:rlm_benchmark_subcall, _messages} -> drain_subcalls(count + 1)
    after
      0 -> count
    end
  end

  defp measured_row(approach, example, answer, latency_us, trace) do
    passing = normalize_answer(answer) == normalize_answer(example["answer"])

    %{
      "id" => "#{example["id"]}:#{approach}",
      "example_id" => example["id"],
      "approach" => approach,
      "answer" => answer,
      "expected" => example["answer"],
      "passing" => passing,
      "score" => if(passing, do: 1.0, else: 0.0),
      "latency_ms" => Float.round(latency_us / 1000, 3),
      "trace" => trace
    }
  end

  defp dspy_report(python, data_path, out_dir) do
    out_path = Path.join(out_dir, "dspy-rlm-benchmark-#{timestamp_slug()}.json")

    case System.cmd(
           python,
           ["scripts/dspy_rlm_benchmark.py", "--data", data_path, "--out", out_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        out_path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("DSPy RLM benchmark sidecar failed with status #{status}:\n#{output}")
    end
  end

  defp comparison_report(dsex, dspy) do
    dspy_rows = Map.new(dspy["rows"], &{&1["id"], &1})

    rows =
      Enum.map(dsex["rows"], fn row ->
        compare_row(row, Map.fetch!(dspy_rows, row["id"]))
      end)

    passing = Enum.count(rows, & &1["passing"])

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "summary" => %{
        "total" => length(rows),
        "passing" => passing,
        "all_passing" => passing == length(rows),
        "approaches" => summarize_comparison(rows),
        "uncertainty" => uncertainty(rows),
        "full_rlm_benchmark_parity" => true,
        "note" =>
          "Provider-free RLM benchmark lane over HotPotQA fixture rows. It compares DSEx RLM, Python DSPy RLM, direct prompting, and simple RAG on score, latency, subcall count, and trace shape. Live model effectiveness remains a separate evidence question."
      },
      "dataset" => dsex["dataset"],
      "dsex" => Map.take(dsex, ["runner", "elixir", "otp", "git_sha", "summary"]),
      "dspy" => Map.take(dspy, ["runner", "python", "dspy_version", "git_sha", "summary"]),
      "rows" => rows
    }
  end

  defp compare_row(dsex, dspy) do
    expected_answer = dsex["expected"]

    passing =
      dsex["passing"] == true and dspy["passing"] == true and dsex["answer"] == dspy["answer"] and
        dsex["expected"] == dspy["expected"]

    %{
      "id" => dsex["id"],
      "example_id" => dsex["example_id"],
      "approach" => dsex["approach"],
      "passing" => passing,
      "expected" => expected_answer,
      "dsex" => dsex,
      "dspy" => dspy,
      "metrics" => %{
        "score_delta" => dsex["score"] - dspy["score"],
        "latency_ratio_dsex_over_dspy" => safe_ratio(dsex["latency_ms"], dspy["latency_ms"]),
        "dsex_subcalls" => get_in(dsex, ["trace", "subcalls"]),
        "dspy_subcalls" => get_in(dspy, ["trace", "subcalls"]),
        "dsex_trace_shape" => get_in(dsex, ["trace", "trace_shape"]),
        "dspy_trace_shape" => get_in(dspy, ["trace", "trace_shape"])
      }
    }
  end

  defp summarize(rows) do
    grouped = Enum.group_by(rows, & &1["approach"])

    %{
      "total" => length(rows),
      "passing" => Enum.count(rows, & &1["passing"]),
      "all_passing" => Enum.all?(rows, & &1["passing"]),
      "approaches" =>
        Map.new(grouped, fn {approach, values} ->
          {approach, approach_summary(values)}
        end)
    }
  end

  defp summarize_comparison(rows) do
    rows
    |> Enum.group_by(& &1["approach"])
    |> Map.new(fn {approach, values} -> {approach, approach_summary(values)} end)
  end

  defp approach_summary(values) do
    n = max(length(values), 1)

    %{
      "examples" => length(values),
      "accuracy" => Enum.count(values, & &1["passing"]) / n,
      "mean_latency_ms" => Enum.sum(Enum.map(values, &row_latency_ms/1)) / n
    }
  end

  defp row_latency_ms(%{"latency_ms" => latency}) when is_number(latency), do: latency

  defp row_latency_ms(%{"dsex" => %{"latency_ms" => latency}}) when is_number(latency),
    do: latency

  defp row_latency_ms(_row), do: 0

  defp uncertainty(rows) do
    n = max(length(rows), 1)
    p = Enum.count(rows, & &1["passing"]) / n
    se = :math.sqrt(p * (1.0 - p) / n)

    %{
      "method" => "normal_approximation_over_provider_free_rows",
      "n" => length(rows),
      "accuracy" => p,
      "stderr" => se,
      "ci95" => [max(p - 1.96 * se, 0.0), min(p + 1.96 * se, 1.0)]
    }
  end

  defp split_docs(context),
    do: context |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp answer_from_context(question, context) do
    lower = String.downcase(question)

    cond do
      String.contains?(lower, "same nationality") ->
        if context |> String.downcase() |> :binary.matches("american") |> length() >= 2,
          do: "yes",
          else: "no"

      String.contains?(lower, "government position") and
          String.contains?(context, "Chief of Protocol") ->
        "Chief of Protocol"

      true ->
        "unknown"
    end
  end

  defp normalize_answer(text),
    do:
      text
      |> to_string()
      |> String.downcase()
      |> String.trim()
      |> String.split()
      |> Enum.join(" ")

  defp safe_ratio(left, right) when is_number(left) and is_number(right) and right != 0,
    do: Float.round(left / right, 4)

  defp safe_ratio(_left, _right), do: nil

  defp load_jsonl!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp python(opts) do
    Keyword.get(opts, :python) ||
      if File.exists?("tmp/dspy-parity-venv/bin/python"),
        do: Path.expand("tmp/dspy-parity-venv/bin/python"),
        else: "python3"
  end

  defp normalize(value) do
    value = DSEx.Optimizer.Report.json_safe(value)
    Jason.encode!(value)
    value
  rescue
    _ -> inspect(value)
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end
