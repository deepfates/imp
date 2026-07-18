# Campaign cell: gsm8k_weak_model
#
# THE QUESTION: on real held-out GSM8K, does optimizing a WEAK student model
# close the weak-to-strong gap — and does any searching/bootstrapping arm beat
# just given demos? The prior GSM8K cell nulled by ceiling (gpt-5.4-mini ~91%,
# no headroom); this cell runs the canonical DSPy shape on a weak student where
# headroom exists by construction.
#
# The STUDENT is chosen by gsm8k_weak_model_probe.exs (first candidate scoring
# in [20%,70%] zero-shot CoT on train rows 0-19). Run the probe FIRST; this
# script reads the chosen student from gsm8k_weak_model-probe.json.
#
# Arms (student = weak model at inference everywhere; 2 temp-0 replicas each,
# scored ONCE per repeat on the 40-row held-out test set 80-119):
#   (a) zero_shot_cot          — baseline
#   (b) labeled_fewshot_k4     — demos from train (question+reasoning+answer)
#   (c) bootstrap_self         — BootstrapFewShot, teacher = the weak model itself
#   (d) bootstrap_strong       — BootstrapFewShot, teacher = gpt-5.4-mini CoT
#   (e) miprov2                — MIPROv2 on dev-20
# Plus a reference line: gpt-5.4-mini zero-shot CoT ONCE on the same test-40.
#
#   cd .../dspy_elixir && set -a && . ./.env && set +a && \
#     mix run benchmarks/runs/campaign-20260718/gsm8k_weak_model.exs
#
# Writes benchmarks/runs/campaign-20260718/gsm8k_weak_model-result.json.

defmodule GSM8KWeakModel do
  @teacher_model "gpt-5.4-mini"
  @data_relative "benchmarks/runs/campaign-20260718/data/gsm8k.json"
  @probe_relative "benchmarks/runs/campaign-20260718/gsm8k_weak_model-probe.json"
  @out "benchmarks/runs/campaign-20260718/gsm8k_weak_model-result.json"
  @repeats 2
  @repeat_timeout_ms 300_000
  @train 0..59
  @dev 60..79
  @test 80..119
  # gpt-*-nano/mini list prices unknown; placeholder for a cost ESTIMATE only.
  @usd_per_input_token 0.15 / 1_000_000
  @usd_per_output_token 0.60 / 1_000_000

  # ---- numeric-exact-match metric ------------------------------------------
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

  def chosen_student! do
    path = Path.join(File.cwd!(), @probe_relative)

    unless File.exists?(path),
      do: raise("probe artifact missing: #{path} — run gsm8k_weak_model_probe.exs first")

    probe = path |> File.read!() |> Jason.decode!()
    student = probe["chosen_student"]
    if is_nil(student), do: raise("probe chose no student (#{probe["chosen_note"]})")
    {student, probe}
  end

  def eval_example(row) do
    Imp.example(question: row["question"], answer: row["final_answer"])
    |> Imp.with_inputs(:question)
  end

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

    prog_right =
      Imp.chain_of_thought("question -> answer", lm: static.(%{reasoning: "x", answer: gold}))

    prog_dollar =
      Imp.chain_of_thought("question -> answer",
        lm: static.(%{reasoning: "x", answer: "$#{gold}.0"})
      )

    prog_wrong =
      Imp.chain_of_thought("question -> answer", lm: static.(%{reasoning: "x", answer: "999999"}))

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

  # ---- usage / cost scan ---------------------------------------------------
  def usage_from_result(result) do
    usages =
      result.rows
      |> Enum.flat_map(fn row -> row.prediction |> collect_usage_maps() |> Enum.uniq() end)

    %{
      "requests_with_usage" => length(usages),
      "input_tokens" => sum_field(usages, [:input_tokens, "input_tokens"]),
      "output_tokens" => sum_field(usages, [:output_tokens, "output_tokens"]),
      "total_tokens" => sum_field(usages, [:total_tokens, "total_tokens"])
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

  # ---- LM builders ---------------------------------------------------------
  def student_lm(student) do
    Imp.req_llm("openai:#{student}", api_key: System.fetch_env!("OPENAI_API_KEY"), temperature: 0)
  end

  def teacher_lm do
    Imp.req_llm("openai:#{@teacher_model}",
      api_key: System.fetch_env!("OPENAI_API_KEY"),
      temperature: 0
    )
  end

  # ---- one scored repeat of an arm -----------------------------------------
  # build_fn.(lm) returns the program to evaluate. It receives a fresh student
  # lm and may run an optimizer (which sees ONLY train/dev).
  def run_arm(name, build_fn, testset, metric, student) do
    IO.puts("\n#### arm: #{name}")

    repeats =
      for repeat <- 1..@repeats do
        Imp.Cache.clear()
        Imp.Cache.reset_stats()
        t0 = System.monotonic_time(:millisecond)

        task =
          Task.async(fn ->
            try do
              lm = student_lm(student)
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

  # ---- reference line: strong model zero-shot, scored ONCE -----------------
  def reference_line(testset, metric) do
    IO.puts("\n#### reference: #{@teacher_model} zero-shot CoT (once)")
    Imp.Cache.clear()
    Imp.Cache.reset_stats()
    t0 = System.monotonic_time(:millisecond)

    result =
      try do
        program = Imp.chain_of_thought("question -> answer", lm: teacher_lm())
        report = Imp.evaluate(program, testset, metric, max_concurrency: 8, timeout: 120_000)
        {:ok, report}
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    wall = (System.monotonic_time(:millisecond) - t0) / 1000
    cache = Imp.Cache.stats()

    case result do
      {:ok, report} ->
        usage = usage_from_result(report)

        IO.puts(
          "   reference score=#{report.score} n=#{length(report.rows)} " <>
            "wall=#{Float.round(wall, 1)}s cache_hits=#{Map.get(cache, :hits, 0)}"
        )

        %{
          model: @teacher_model,
          status: :ok,
          score: report.score,
          row_scores: Enum.map(report.rows, & &1.score),
          n: length(report.rows),
          errors: length(report.errors),
          wall_seconds: Float.round(wall, 2),
          cache: %{hits: Map.get(cache, :hits, 0), misses: Map.get(cache, :misses, 0)},
          usage: usage,
          cost_usd_est: cost(usage)
        }

      {:error, err} ->
        IO.puts("   reference ERROR: " <> String.slice(err, 0, 300))
        %{model: @teacher_model, status: :error, error: String.slice(err, 0, 2000)}
    end
  end

  # ---- main ----------------------------------------------------------------
  def main do
    {rows, sha, n} = load()
    {student, probe} = chosen_student!()
    IO.puts("data rows=#{n} sha256=#{sha}")
    IO.puts("chosen student=#{student} (#{probe["chosen_note"]})")

    preflight!(rows)

    trainset = slice(rows, @train) |> Enum.map(&demo_example/1)
    devset = slice(rows, @dev) |> Enum.map(&eval_example/1)
    testset = slice(rows, @test) |> Enum.map(&eval_example/1)

    IO.puts("split: train=#{length(trainset)} dev=#{length(devset)} test=#{length(testset)}")

    m = metric()

    arm_specs = [
      {"a_zero_shot_cot", fn lm -> Imp.chain_of_thought("question -> answer", lm: lm) end},
      {"b_labeled_fewshot_k4",
       fn lm ->
         program = Imp.chain_of_thought("question -> answer", lm: lm)
         Imp.optimize(program, Imp.Optimizer.LabeledFewShot.new(k: 4), trainset)
       end},
      {"c_bootstrap_self",
       fn lm ->
         program = Imp.chain_of_thought("question -> answer", lm: lm)

         opt =
           Imp.Optimizer.BootstrapFewShot.new(m,
             max_bootstrapped_demos: 4,
             max_labeled_demos: 0,
             timeout: 180_000
           )

         # default teacher = copy of student (the weak model) => self-bootstrap
         Imp.optimize(program, opt, trainset)
       end},
      {"d_bootstrap_strong",
       fn lm ->
         student_program = Imp.chain_of_thought("question -> answer", lm: lm)
         teacher_program = Imp.chain_of_thought("question -> answer", lm: teacher_lm())

         opt =
           Imp.Optimizer.BootstrapFewShot.new(m,
             max_bootstrapped_demos: 4,
             max_labeled_demos: 0,
             timeout: 180_000
           )

         # teacher: reaches compile/4 only via direct compile (Imp.optimize
         # rejects non-dataset opts); the compiled student keeps the weak lm at
         # inference — distillation by demos.
         Imp.Optimizer.BootstrapFewShot.compile(opt, student_program, trainset,
           teacher: teacher_program
         )
       end},
      {"e_miprov2",
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
             minibatch_size: 15
           )

         Imp.optimize(program, opt, trainset, devset)
       end}
    ]

    # reference line first (cheap, one call set), then arms; write after each.
    reference = reference_line(testset, m)
    write_artifact([], reference, sha, n, student, probe)

    arms =
      Enum.reduce(arm_specs, [], fn {name, build_fn}, acc ->
        arm = run_arm(name, build_fn, testset, m, student)
        done = acc ++ [arm]
        write_artifact(done, reference, sha, n, student, probe)
        done
      end)

    write_artifact(arms, reference, sha, n, student, probe)
    IO.puts("\nartifact: #{Path.join(File.cwd!(), @out)}")

    # summary table to stdout
    IO.puts("\n== ARMS TABLE (mean over replicas) ==")

    Enum.each(arms, fn arm ->
      oks = Enum.filter(arm.repeats, &(&1.status == :ok))
      scores = Enum.map(oks, & &1.score)

      mean =
        if scores == [], do: "n/a", else: Float.round(Enum.sum(scores) / length(scores), 4)

      reps = Enum.map(arm.repeats, fn r -> if r.status == :ok, do: r.score, else: :err end)
      IO.puts("   #{arm.name}: mean=#{mean} replicas=#{inspect(reps)}")
    end)

    ref_str = if reference.status == :ok, do: reference.score, else: :err
    IO.puts("   reference(#{@teacher_model}): #{ref_str}")
  end

  defp write_artifact(arms, reference, sha, n, student, probe) do
    artifact = %{
      "cell" => "gsm8k_weak_model",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "student_model" => student,
      "teacher_model" => @teacher_model,
      "temperature" => 0,
      "repeat_semantics" => "temp-0 replicas",
      "program" => "Imp.chain_of_thought(\"question -> answer\")",
      "metric" => "numeric exact match on final answer (last number token, $/,/% stripped)",
      "step1_probe" => %{
        "chosen_student" => student,
        "chosen_note" => probe["chosen_note"],
        "window" => [0.20, 0.70],
        "probes" =>
          Enum.map(probe["probes"] || [], fn p ->
            %{
              "model" => p["model"],
              "status" => p["status"],
              "score" => p["score"],
              "in_window" => p["in_window"]
            }
          end)
      },
      "dataset" => %{"path" => @data_relative, "sha256" => sha, "rows" => n},
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
        "reference_scored_once" => true,
        "cost_pricing_note" =>
          "cost_usd_est is APPROXIMATE: list prices unknown; " <>
            "used $0.15/1M input + $0.60/1M output placeholder for all models"
      },
      "arm_semantics" => %{
        "a_zero_shot_cot" => "baseline, weak student zero-shot",
        "b_labeled_fewshot_k4" => "LabeledFewShot k=4, train demos (q+reasoning+answer)",
        "c_bootstrap_self" =>
          "BootstrapFewShot max_bootstrapped=4 max_labeled=0, teacher=weak student itself",
        "d_bootstrap_strong" =>
          "BootstrapFewShot max_bootstrapped=4 max_labeled=0, teacher=#{@teacher_model} CoT (distillation by demos)",
        "e_miprov2" =>
          "MIPROv2 auto=nil num_candidates=4 num_trials=8 max_bootstrapped=2 max_labeled=2 startup_trials=2 minibatch=15 on dev-20"
      },
      "reference_line" => reference,
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

GSM8KWeakModel.main()
