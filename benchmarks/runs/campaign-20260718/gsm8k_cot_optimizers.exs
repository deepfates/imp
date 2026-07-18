# Campaign cell: gsm8k_cot_optimizers
#
# THE QUESTION: does bootstrapped reasoning beat zero-shot CoT on held-out real
# GSM8K math? Program is Imp.chain_of_thought("question -> answer"). Four arms,
# 2 temp-0 replica repeats each, scored ONCE per repeat on a 40-example held-out
# test set that no optimizer ever sees.
#
#   cd .../dspy_elixir && set -a && . ./.env && set +a && \
#     mix run benchmarks/runs/campaign-20260718/gsm8k_cot_optimizers.exs
#
# Writes benchmarks/runs/campaign-20260718/gsm8k_cot_optimizers-result.json.

defmodule GSM8KCotOptimizers do
  @model "openai:gpt-5.4-mini"
  @data_relative "benchmarks/runs/campaign-20260718/data/gsm8k.json"
  @out "benchmarks/runs/campaign-20260718/gsm8k_cot_optimizers-result.json"
  @repeats 2
  # hard ceiling per repeat (optimizer build + held-out evaluate). A stall past
  # this becomes a recorded :timeout error instead of hanging the whole cell.
  @repeat_timeout_ms 280_000
  # split, in order
  @train 0..59
  @dev 60..79
  @test 80..119
  # rough token pricing for a cost ESTIMATE only (gpt-5.4-mini list price not
  # published; use a gpt-*-mini-class placeholder and flag it as approximate).
  @usd_per_input_token 0.15 / 1_000_000
  @usd_per_output_token 0.60 / 1_000_000

  # ---- numeric-exact-match metric ------------------------------------------

  # Pull the final numeric value out of a free-text answer field: strip $ , %
  # and whitespace, take the last number-like token, drop a trailing .0.
  def normalize(nil), do: :error

  def normalize(value) when is_number(value), do: normalize(to_string(value))

  def normalize(text) when is_binary(text) do
    cleaned = text |> String.replace(~r/[\$,%]/, "") |> String.trim()

    numbers = Regex.scan(~r/-?\d+(?:\.\d+)?/, cleaned) |> Enum.map(&hd/1)

    case List.last(numbers) do
      nil ->
        :error

      token ->
        case Float.parse(token) do
          {f, _} -> Float.round(f, 6)
          :error -> :error
        end
    end
  end

  def metric do
    fn example, prediction ->
      gold = normalize(Imp.Example.get(example, :answer))
      pred = normalize(Imp.Prediction.get(prediction, :answer))
      if gold != :error and pred != :error and gold == pred, do: 1.0, else: 0.0
    end
  end

  # ---- data ----------------------------------------------------------------

  def load do
    path = Path.join(File.cwd!(), @data_relative)
    bytes = File.read!(path)
    data = Jason.decode!(bytes)
    rows = data["rows"]
    {rows, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower), length(rows)}
  end

  # test/dev examples carry the gold final answer for scoring only.
  def eval_example(row) do
    Imp.example(question: row["question"], answer: row["final_answer"])
    |> Imp.with_inputs(:question)
  end

  # train examples for LabeledFewShot demos carry a reasoning trace (mapped from
  # the corpus answer_text) plus the final answer, so CoT demos render both the
  # :reasoning and :answer output fields.
  def demo_example(row) do
    Imp.example(
      question: row["question"],
      reasoning: row["answer_text"],
      answer: row["final_answer"]
    )
    |> Imp.with_inputs(:question)
  end

  def slice(rows, range), do: Enum.map(Enum.slice(rows, range), & &1)

  # ---- preflight: prove the metric on static rows BEFORE spending -----------

  def preflight!(rows) do
    r0 = Enum.at(rows, 0)
    gold = r0["final_answer"]

    static = fn payload ->
      %{module: Imp.LM.Static, opts: [handler: fn _m, _o -> payload end]}
    end

    ex = eval_example(r0)
    m = metric()

    prog_right = Imp.chain_of_thought("question -> answer", lm: static.(%{reasoning: "x", answer: gold}))
    prog_dollar = Imp.chain_of_thought("question -> answer", lm: static.(%{reasoning: "x", answer: "$#{gold}.0"}))
    prog_wrong = Imp.chain_of_thought("question -> answer", lm: static.(%{reasoning: "x", answer: "999999"}))

    {:ok, p_right} = Imp.call(prog_right, %{question: r0["question"]})
    {:ok, p_dollar} = Imp.call(prog_dollar, %{question: r0["question"]})
    {:ok, p_wrong} = Imp.call(prog_wrong, %{question: r0["question"]})

    checks = [
      {"exact", m.(ex, p_right), 1.0},
      {"dollar+.0 normalized", m.(ex, p_dollar), 1.0},
      {"wrong", m.(ex, p_wrong), 0.0}
    ]

    IO.puts("== preflight (gold=#{gold})")

    Enum.each(checks, fn {name, got, want} ->
      IO.puts("   #{name}: got #{got} want #{want}")
      unless got == want, do: raise("metric preflight FAILED: #{name} got #{got} want #{want}")
    end)

    IO.puts("   metric OK")
  end

  # ---- usage / cost scan (from the ticket template) ------------------------

  def usage_from_result(result) do
    usages =
      result.rows
      |> Enum.flat_map(fn row -> row.prediction |> collect_usage_maps() |> Enum.uniq() end)

    input = sum_field(usages, [:input_tokens, "input_tokens"])
    output = sum_field(usages, [:output_tokens, "output_tokens"])
    total = sum_field(usages, [:total_tokens, "total_tokens"])

    %{
      "requests_with_usage" => length(usages),
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => total
    }
  end

  defp collect_usage_maps(nil), do: []
  defp collect_usage_maps(%_s{} = s), do: s |> Map.from_struct() |> collect_usage_maps()

  defp collect_usage_maps(map) when is_map(map) do
    own = if usage_map?(map), do: [map], else: []
    own ++ Enum.flat_map(Map.values(map), &collect_usage_maps/1)
  end

  defp collect_usage_maps(list) when is_list(list), do: Enum.flat_map(list, &collect_usage_maps/1)
  defp collect_usage_maps(_), do: []

  defp usage_map?(map) do
    Enum.any?([:input_tokens, "input_tokens"], &Map.has_key?(map, &1)) and
      Enum.any?([:output_tokens, "output_tokens"], &Map.has_key?(map, &1))
  end

  defp sum_field(maps, keys) do
    maps
    |> Enum.map(fn map ->
      Enum.find_value(keys, 0, fn key ->
        case Map.get(map, key) do
          v when is_number(v) -> v
          _ -> nil
        end
      end)
    end)
    |> Enum.sum()
  end

  defp cost(usage) do
    Float.round(
      usage["input_tokens"] * @usd_per_input_token + usage["output_tokens"] * @usd_per_output_token,
      6
    )
  end

  # ---- one scored repeat of an arm -----------------------------------------

  # build_fn.(lm) must return the program to evaluate on the held-out test set.
  # It receives a fresh lm and may run an optimizer (which sees ONLY train/dev).
  def run_arm(name, build_fn, testset, metric) do
    IO.puts("\n#### arm: #{name}")

    repeats =
      for repeat <- 1..@repeats do
        Imp.Cache.clear()
        Imp.Cache.reset_stats()

        t0 = System.monotonic_time(:millisecond)

        task =
          Task.async(fn ->
            try do
              lm = Imp.req_llm(@model, api_key: System.fetch_env!("OPENAI_API_KEY"), temperature: 0)
              program = build_fn.(lm)
              report = Imp.evaluate(program, testset, metric, max_concurrency: 8, timeout: 120_000)
              {:ok, report}
            rescue
              e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end
          end)

        result =
          case Task.yield(task, @repeat_timeout_ms) || Task.shutdown(task, :brutal_kill) do
            {:ok, value} -> value
            nil -> {:error, "TIMEOUT: repeat exceeded #{@repeat_timeout_ms}ms"}
          end

        wall = (System.monotonic_time(:millisecond) - t0) / 1000
        cache = Imp.Cache.stats()

        case result do
          {:ok, report} ->
            usage = usage_from_result(report)
            row_scores = Enum.map(report.rows, & &1.score)

            IO.puts(
              "   repeat #{repeat}: score=#{report.score} n=#{length(report.rows)} " <>
                "errors=#{length(report.errors)} wall=#{Float.round(wall, 1)}s " <>
                "cache_hits=#{Map.get(cache, :hits, 0)}"
            )

            %{
              repeat: repeat,
              status: :ok,
              score: report.score,
              row_scores: row_scores,
              n: length(report.rows),
              errors: length(report.errors),
              wall_seconds: Float.round(wall, 2),
              cache: %{
                hits: Map.get(cache, :hits, 0),
                misses: Map.get(cache, :misses, 0),
                bypasses: Map.get(cache, :bypasses, 0)
              },
              usage: usage,
              cost_usd_est: cost(usage)
            }

          {:error, err} ->
            IO.puts("   repeat #{repeat}: ERROR (#{Float.round(wall, 1)}s)")
            IO.puts(err |> String.slice(0, 400))

            %{
              repeat: repeat,
              status: :error,
              error: String.slice(err, 0, 2000),
              wall_seconds: Float.round(wall, 2)
            }
        end
      end

    %{name: name, repeats: repeats}
  end

  # ---- main ----------------------------------------------------------------

  def main do
    {rows, sha, n} = load()
    IO.puts("data rows=#{n} sha256=#{sha}")

    preflight!(rows)

    trainset = slice(rows, @train) |> Enum.map(&demo_example/1)
    devset = slice(rows, @dev) |> Enum.map(&eval_example/1)
    testset = slice(rows, @test) |> Enum.map(&eval_example/1)

    IO.puts("split: train=#{length(trainset)} dev=#{length(devset)} test=#{length(testset)}")

    m = metric()

    arm_specs = [
      {"zero_shot_cot", fn lm -> Imp.chain_of_thought("question -> answer", lm: lm) end},
      {"labeled_fewshot_k4",
       fn lm ->
         program = Imp.chain_of_thought("question -> answer", lm: lm)
         Imp.optimize(program, Imp.Optimizer.LabeledFewShot.new(k: 4), trainset)
       end},
      {"bootstrap_fewshot_4",
       fn lm ->
         program = Imp.chain_of_thought("question -> answer", lm: lm)

         opt =
           Imp.Optimizer.BootstrapFewShot.new(m,
             max_bootstrapped_demos: 4,
             max_labeled_demos: 0,
             timeout: 180_000
           )

         Imp.optimize(program, opt, trainset)
       end},
      {"miprov2",
       fn lm ->
         program = Imp.chain_of_thought("question -> answer", lm: lm)

         opt =
           Imp.Optimizer.MIPROv2.new(m,
             auto: nil,
             num_candidates: 4,
             num_trials: 8,
             max_bootstrapped_demos: 2,
             max_labeled_demos: 2,
             startup_trials: 2,
             # dev/valset is 20; the default minibatch_size (35) exceeds it, so
             # size it to the valset as a user would.
             minibatch_size: 15
           )

         Imp.optimize(program, opt, trainset, devset)
       end}
    ]

    # Run arms sequentially, writing the artifact after each so a mid-run kill
    # never loses a completed arm.
    arms =
      Enum.reduce(arm_specs, [], fn {name, build_fn}, acc ->
        arm = run_arm(name, build_fn, testset, m)
        done = acc ++ [arm]
        write_artifact(done, sha, n, devset)
        done
      end)

    write_artifact(arms, sha, n, devset)
    IO.puts("\nartifact: #{Path.join(File.cwd!(), @out)}")
  end

  defp write_artifact(arms, sha, n, _devset) do
    artifact = %{
      "cell" => "gsm8k_cot_optimizers",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => @model,
      "temperature" => 0,
      "repeat_semantics" => "temp-0 replicas",
      "program" => "Imp.chain_of_thought(\"question -> answer\")",
      "metric" => "numeric exact match on final answer (last number token, $/,/% stripped)",
      "dataset" => %{
        "path" => @data_relative,
        "sha256" => sha,
        "rows" => n
      },
      "split" => %{
        "order" => "in-file order, no shuffle",
        "train" => %{"range" => "0-59", "n" => Enum.count(@train)},
        "dev" => %{"range" => "60-79", "n" => Enum.count(@dev)},
        "test" => %{"range" => "80-119", "n" => Enum.count(@test), "held_out" => true}
      },
      "controls" => %{
        "test_scored_once_per_repeat" => true,
        "optimizers_see" => "train (and dev for MIPROv2) only; never test",
        "cache_cleared_before_each_repeat" => true,
        "cost_pricing_note" =>
          "cost_usd_est is APPROXIMATE: gpt-5.4-mini list price unknown; " <>
            "used $0.15/1M input + $0.60/1M output placeholder"
      },
      "arms" => arms
    }

    out = Path.join(File.cwd!(), @out)
    File.write!(out, Jason.encode!(artifact, pretty: true) <> "\n")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end

GSM8KCotOptimizers.main()
