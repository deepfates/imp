defmodule Mix.Tasks.Imp.Benchmark.Overhead do
  @moduledoc """
  Run provider-free Imp-vs-DSPy overhead benchmarks.

      mix imp.benchmark.overhead

  Evidence capture requires a clean checkout by default. `--no-require-clean`
  is available only for diagnostics; the dashboard rejects that dirty envelope.

  This benchmark deliberately excludes provider latency. It measures local
  library overhead for formatting, parsing, validation, evaluation, optimizer
  scheduling, redaction/serialization, cache, and concurrency paths.
  """

  use Mix.Task

  @shortdoc "Run provider-free Imp-vs-DSPy overhead benchmarks"

  @default_out_dir Imp.BenchmarkTruth.Paths.runs("overhead")
  @dspy_script "scripts/dspy_overhead_benchmark.py"
  alias Imp.BenchmarkTruth.{ArtifactFile, OverheadPolicy, RunContext}

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
          require_clean: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    iterations = Keyword.get(opts, :iterations, 200)
    warmup = Keyword.get(opts, :warmup, 20)
    batch_size = Keyword.get(opts, :batch_size, 10)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    validate_positive!(:iterations, iterations)
    validate_non_negative!(:warmup, warmup)
    validate_positive!(:batch_size, batch_size)
    File.mkdir_p!(out_dir)

    context =
      RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, true),
        inputs: %{
          "protocol_id" => "provider_free_overhead_regression_guard_v2",
          "iterations" => iterations,
          "warmup" => warmup,
          "batch_size" => batch_size,
          "policy" => OverheadPolicy.budgets()
        }
      )

    imp = imp_report(iterations, warmup, batch_size, context.environment)
    dspy = dspy_report(python(opts), out_dir, iterations, warmup, batch_size)
    report = comparison_report(imp, dspy)
    out_path = Path.join(out_dir, "overhead-parity-#{timestamp_slug()}.json")

    %{artifact: report, path: out_path} =
      ArtifactFile.write_run_json!(out_path, report, context)

    Mix.shell().info("overhead regression report: #{out_path}")

    Mix.shell().info(
      "overhead cases passing threshold: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_passing"] do
      Mix.raise("overhead regression guard failed; inspect #{out_path}")
    end
  end

  defp imp_report(iterations, warmup, batch_size, environment) do
    cases = benchmark_cases()

    %{
      "schema_version" => 1,
      "runner" => "imp-overhead",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "schedulers" => System.schedulers_online(),
      "environment" => environment,
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
    schema_signature = Imp.signature("text -> label: string, score: number")
    schema_value = %{label: "ok", score: 1.0}
    cache_hit_key = {:overhead_hit, :paired_lookup}
    Imp.Cache.put(cache_hit_key, response)

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
       fn -> Imp.Schema.validate_fields(schema_signature.outputs, schema_value) end},
      {"evaluation_loop",
       fn -> examples |> Imp.Evaluate.new(metric) |> Imp.Evaluate.run(program) end},
      {"metric_normalization",
       fn ->
         prediction = Imp.Prediction.new(%{answer: "Paris"})
         Enum.map(examples, &metric.(&1, prediction))
       end},
      {"optimizer_trial_scheduling",
       fn ->
         Imp.Optimizer.BootstrapFewShot.new(metric,
           max_bootstrapped_demos: 1,
           max_labeled_demos: 1
         )
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
      {"cache_hit", fn -> Imp.Cache.get(cache_hit_key) end},
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
    verify_reference_script!()
    out_path = Path.join(out_dir, "dspy-overhead-#{timestamp_slug()}.json")

    args = [
      @dspy_script,
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
        report = out_path |> File.read!() |> Jason.decode!()
        validate_reference_report!(report, iterations, warmup, batch_size)
        report

      {output, status} ->
        Mix.raise("DSPy overhead benchmark failed with status #{status}:\n#{output}")
    end
  end

  defp comparison_report(imp, dspy) do
    imp_cases = case_index!(imp["cases"], "Imp")
    dspy_cases = case_index!(dspy["cases"], "DSPy")

    cases =
      imp_cases
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn id ->
        OverheadPolicy.evaluate!(id, imp_cases[id], Map.fetch!(dspy_cases, id))
      end)

    passing = Enum.count(cases, & &1["passing"])

    %{
      "schema_version" => 2,
      "runner" => "imp-dspy-overhead-regression-guard",
      "policy" => %{
        "id" => "named_per_operation_v1",
        "ratios_are_measurements_not_speed_claims" => true,
        "budgets" => OverheadPolicy.budgets()
      },
      "summary" => %{
        "total" => length(cases),
        "passing" => passing,
        "all_passing" => passing == length(cases),
        "note" =>
          "Named absolute and reference-relative budgets are regression guards. Ratios are measurements, not parity, superiority, or speed claims."
      },
      "imp" =>
        Map.take(imp, [
          "runner",
          "elixir",
          "otp",
          "schedulers",
          "environment",
          "iterations",
          "warmup",
          "batch_size"
        ]),
      "dspy" =>
        Map.take(dspy, [
          "runner",
          "python",
          "dspy_version",
          "environment",
          "iterations",
          "warmup",
          "batch_size"
        ]),
      "cases" => cases
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

  defp case_index!(cases, runtime) when is_list(cases) do
    ids = Enum.map(cases, & &1["id"])
    expected = OverheadPolicy.expected_case_ids()

    unless length(ids) == length(Enum.uniq(ids)) and Enum.sort(ids) == expected do
      Mix.raise(
        "#{runtime} overhead case IDs must match exactly once: expected #{inspect(expected)}, got #{inspect(ids)}"
      )
    end

    Map.new(cases, &{&1["id"], &1})
  end

  defp case_index!(_cases, runtime), do: Mix.raise("#{runtime} overhead cases must be a list")

  defp verify_reference_script! do
    actual =
      @dspy_script
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    unless actual == OverheadPolicy.script_sha256() do
      Mix.raise(
        "DSPy overhead script SHA-256 mismatch: expected #{OverheadPolicy.script_sha256()}, got #{actual}"
      )
    end
  end

  defp validate_reference_report!(report, iterations, warmup, batch_size) do
    environment = report["environment"] || %{}

    valid? =
      report["runner"] == "python-dspy-overhead" and
        report["dspy_version"] == OverheadPolicy.dspy_version() and
        environment["script_sha256"] == OverheadPolicy.script_sha256() and
        is_binary(environment["system"]) and is_binary(environment["machine"]) and
        is_binary(environment["python_implementation"]) and
        is_binary(environment["python_executable"]) and report["iterations"] == iterations and
        report["warmup"] == warmup and report["batch_size"] == batch_size

    unless valid? do
      Mix.raise(
        "DSPy overhead reference identity mismatch; expected DSPy #{OverheadPolicy.dspy_version()} and pinned script #{OverheadPolicy.script_sha256()}"
      )
    end
  end

  defp validate_positive!(_name, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(name, value),
    do: Mix.raise("#{name} must be a positive integer, got: #{inspect(value)}")

  defp validate_non_negative!(_name, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative!(name, value),
    do: Mix.raise("#{name} must be a non-negative integer, got: #{inspect(value)}")

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
