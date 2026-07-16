defmodule Mix.Tasks.Imp.Benchmark.Overhead do
  @moduledoc """
  Run provider-free Imp-vs-DSPy overhead benchmarks.

      mix imp.benchmark.overhead

  This benchmark deliberately excludes provider latency. It measures local
  library overhead for formatting, parsing, validation, evaluation, optimizer
  scheduling, redaction/serialization, cache, and concurrency paths.
  """

  use Mix.Task

  @shortdoc "Run provider-free Imp-vs-DSPy overhead benchmarks"

  @default_out_dir Imp.BenchmarkTruth.Paths.runs("overhead")

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          iterations: :integer,
          warmup: :integer,
          batch_size: :integer,
          out: :string,
          python: :string,
          max_ratio: :float
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    iterations = Keyword.get(opts, :iterations, 200)
    warmup = Keyword.get(opts, :warmup, 20)
    batch_size = Keyword.get(opts, :batch_size, 10)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    max_ratio = Keyword.get(opts, :max_ratio, 5.0)
    File.mkdir_p!(out_dir)

    imp = imp_report(iterations, warmup, batch_size)
    dspy = dspy_report(python(opts), out_dir, iterations, warmup, batch_size)
    report = comparison_report(imp, dspy, max_ratio)
    out_path = Path.join(out_dir, "overhead-parity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("overhead parity report: #{out_path}")

    Mix.shell().info(
      "overhead cases passing threshold: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_passing"] do
      Mix.raise("overhead parity failed; inspect #{out_path}")
    end
  end

  defp imp_report(iterations, warmup, batch_size) do
    cases = benchmark_cases()

    %{
      "schema_version" => 1,
      "runner" => "imp-overhead",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "schedulers" => System.schedulers_online(),
      "iterations" => iterations,
      "warmup" => warmup,
      "batch_size" => batch_size,
      "cases" =>
        Enum.map(cases, fn {id, fun} ->
          measure(id, fun, iterations, warmup, batch_size)
        end)
    }
  end

  defp benchmark_cases do
    signature = Imp.signature("question -> answer", "Answer the question.")
    response = "[[ ## answer ## ]]\nParis"
    examples = Enum.map(1..8, &example/1)
    metric = Imp.Metrics.exact_match(:answer)

    program =
      Imp.predict(signature,
        lm: fn _messages, _opts -> {:ok, response} end,
        adapter: Imp.Adapter.Chat
      )

    [
      {"signature_parse", fn -> Imp.Signature.ensure("question -> answer") end},
      {"adapter_format",
       fn ->
         Imp.Adapter.Chat.format(signature, %{question: "What is the capital of France?"},
           demos: []
         )
       end},
      {"adapter_parse", fn -> Imp.Adapter.Chat.parse(signature, response, []) end},
      {"schema_validate",
       fn -> Imp.Schema.validate_fields(signature.outputs, %{answer: "Paris"}) end},
      {"evaluation_loop",
       fn -> examples |> Imp.Evaluate.new(metric) |> Imp.Evaluate.run(program) end},
      {"metric_normalization",
       fn ->
         prediction = Imp.Prediction.new(%{answer: "Paris"})
         Enum.map(examples, &metric.(&1, prediction))
       end},
      {"optimizer_trial_scheduling",
       fn ->
         Imp.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: 1)
         |> Imp.Optimizer.BootstrapFewShot.compile(program, Enum.take(examples, 2))
       end},
      {"trace_redaction_serialization",
       fn ->
         %{
           messages: [%{role: :user, content: "hello"}],
           api_key: "sk-test-secretsecret",
           nested: %{authorization: "Bearer test-secret-secret"}
         }
         |> Imp.Redaction.redact()
         |> Jason.encode!()
       end},
      {"cache_hit",
       fn ->
         Imp.Cache.put(:overhead_hit, response)
         Imp.Cache.get(:overhead_hit)
       end},
      {"cache_miss",
       fn ->
         key = {:overhead_miss, System.unique_integer([:positive])}
         Imp.Cache.fetch_or_store(key, fn -> response end)
       end},
      {"concurrent_orchestration",
       fn ->
         1..32
         |> Imp.Tasks.async_stream(fn value -> value * value end,
           max_concurrency: min(8, System.schedulers_online())
         )
         |> Enum.to_list()
       end}
    ]
  end

  defp example(index) do
    Imp.example(question: "q#{index}", answer: "Paris")
    |> Imp.Example.with_inputs([:question])
  end

  defp measure(id, fun, iterations, warmup, batch_size) do
    Enum.each(1..warmup, fn _ ->
      Enum.each(1..batch_size, fn _ -> fun.() end)
    end)

    samples =
      Enum.map(1..iterations, fn _ ->
        {microseconds, _value} =
          :timer.tc(fn ->
            Enum.each(1..batch_size, fn _ -> fun.() end)
          end)

        microseconds / batch_size
      end)

    summarize(id, samples)
  end

  defp summarize(id, samples) do
    sorted = Enum.sort(samples)

    %{
      "id" => id,
      "iterations" => length(samples),
      "median_us" => percentile(sorted, 0.5),
      "mean_us" => Float.round(Enum.sum(samples) / length(samples), 3),
      "p95_us" => percentile(sorted, 0.95),
      "min_us" => List.first(sorted),
      "max_us" => List.last(sorted)
    }
  end

  defp percentile(sorted, quantile) do
    index =
      ((length(sorted) - 1) * quantile)
      |> Float.round()
      |> trunc()

    Enum.at(sorted, index)
  end

  defp dspy_report(python, out_dir, iterations, warmup, batch_size) do
    out_path = Path.join(out_dir, "dspy-overhead-#{timestamp_slug()}.json")

    args = [
      "scripts/dspy_overhead_benchmark.py",
      "--iterations",
      to_string(iterations),
      "--warmup",
      to_string(warmup),
      "--batch-size",
      to_string(batch_size),
      "--out",
      out_path
    ]

    case System.cmd(python, args, stderr_to_stdout: true) do
      {_output, 0} ->
        out_path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("DSPy overhead benchmark failed with status #{status}:\n#{output}")
    end
  end

  defp comparison_report(imp, dspy, max_ratio) do
    imp_cases = Map.new(imp["cases"], &{&1["id"], &1})
    dspy_cases = Map.new(dspy["cases"], &{&1["id"], &1})

    cases =
      imp_cases
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn id ->
        compare_case(id, imp_cases[id], dspy_cases[id], max_ratio)
      end)

    passing = Enum.count(cases, & &1["passing"])

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "max_ratio" => max_ratio,
      "summary" => %{
        "total" => length(cases),
        "passing" => passing,
        "all_passing" => passing == length(cases),
        "note" =>
          "Provider-free overhead ratios compare local library work only; they do not measure model quality or provider latency."
      },
      "imp" =>
        Map.take(imp, [
          "runner",
          "elixir",
          "otp",
          "schedulers",
          "iterations",
          "warmup",
          "batch_size"
        ]),
      "dspy" =>
        Map.take(dspy, ["runner", "python", "dspy_version", "iterations", "warmup", "batch_size"]),
      "cases" => cases
    }
  end

  defp compare_case(id, imp, dspy, max_ratio) do
    ratio = Float.round(imp["median_us"] / max(dspy["median_us"], 0.001), 4)

    %{
      "id" => id,
      "passing" => ratio <= max_ratio,
      "median_ratio_imp_over_dspy" => ratio,
      "imp" => imp,
      "dspy" => dspy
    }
  end

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
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
end
