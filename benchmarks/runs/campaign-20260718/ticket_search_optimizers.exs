# Campaign cell: ticket_search_optimizers
#
# The decisive transfer test on the committed support-ticket routing task.
# Program: the tutorial's predict router (ticket -> team enum, JSON adapter,
# json_retries: 1). Metric: Imp.exact_match(:team).
#
# Arms (2 repeats each, held-out test-20 scored once per arm-repeat):
#   1 zero-shot
#   2 LabeledFewShot(k: 8)
#   3 BootstrapFewShot(max_bootstrapped_demos: 8, max_labeled_demos: 0, timeout: 120s), teacher=self
#   4 RandomSearch(candidates: 8, demos_per_candidate: 4)      -> optimize/4 with dev-20
#   5 MIPROv2(auto: nil, num_candidates: 4, num_trials: 8,
#            max_bootstrapped_demos: 4, max_labeled_demos: 4, startup_trials: 2) -> optimize/4 dev-20
#   6 COPRO (proposer_lm = same LM)                            -> optimize/3 trainset
#   7 GEPA (feedback metric, reflection_lm = same LM)          -> optimize/4 dev-20
#
# The question: does ANY searching optimizer match/beat given-demos LabeledFewShot
# (~0.85), or beat zero-shot baseline with demos/instructions it DISCOVERED?
#
#   cd .../dspy_elixir && set -a && . ./.env && set +a && \
#     mix run benchmarks/runs/campaign-20260718/ticket_search_optimizers.exs

defmodule TicketSearchOptimizers do
  @model "openai:gpt-5.4-mini"
  @dataset_relative "priv/tutorial/support_tickets.json"
  @out_dir "benchmarks/runs/campaign-20260718"
  @out_file "ticket_search_optimizers-result.json"
  @repeats 2
  # Rough public rate card for a "mini" tier, USD per 1e6 tokens. Cost is an
  # ESTIMATE labeled as such; the load-bearing controls are token counts and
  # live cache-miss counts, both recorded verbatim. Only held-out eval tokens
  # are captured (not compile-phase tokens), so cost_usd_est is a floor.
  @usd_per_m_input 0.15
  @usd_per_m_output 0.60

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    dataset_path = Application.app_dir(:imp, @dataset_relative)
    dataset_bytes = File.read!(dataset_path)
    data = Jason.decode!(dataset_bytes)

    trainset = to_examples(data["train"])
    devset = to_examples(data["dev"])
    testset = to_examples(data["test"])

    data_sha = sha256(dataset_bytes)

    IO.puts(
      "dataset sha256=#{data_sha} train=#{length(trainset)} dev=#{length(devset)} test=#{length(testset)}"
    )

    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    router =
      "ticket -> team: enum[atlas,harbor,beacon,quill]"
      |> Imp.signature(
        "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
      )
      |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

    metric = Imp.exact_match(:team)

    charter = %{
      "atlas" => "money: charges, refunds, invoices, plans, taxes, receipts",
      "harbor" =>
        "platform: outages, errors, latency, queues, technical failures even when payment/email is involved",
      "beacon" =>
        "identity & trust: accounts, credentials, sessions, permissions, data exposure, lockouts",
      "quill" => "product experience: feature requests, how-to questions, documentation"
    }

    gepa_metric = fn example, prediction ->
      gold = normalize(Imp.Example.get(example, :team))
      pred = normalize(Imp.Prediction.get(prediction, :team))
      score = if gold == pred and gold != "", do: 1.0, else: 0.0

      feedback =
        if score == 1.0 do
          "correct: #{gold}"
        else
          reminder = Map.get(charter, gold, "the correct squad")
          "expected #{gold} (#{reminder}); got #{inspect(pred)}"
        end

      %{score: score, feedback: feedback}
    end

    # Arm definitions. Each :run builds a compiled program given (router, train, dev).
    arms = [
      %{
        name: "zero_shot",
        run: fn program, _train, _dev -> program end
      },
      %{
        name: "labeled_fewshot_k8",
        run: fn program, train, _dev ->
          Imp.optimize(program, Imp.Optimizer.LabeledFewShot.new(k: 8), train)
        end
      },
      %{
        name: "bootstrap_fewshot_b8",
        run: fn program, train, _dev ->
          opt =
            Imp.Optimizer.BootstrapFewShot.new(metric,
              max_bootstrapped_demos: 8,
              max_labeled_demos: 0,
              timeout: 120_000
            )

          Imp.optimize(program, opt, train)
        end
      },
      %{
        name: "random_search_c8_d4",
        run: fn program, train, dev ->
          opt =
            Imp.Optimizer.RandomSearch.new(metric,
              candidates: 8,
              demos_per_candidate: 4,
              max_labeled_demos: 0
            )

          Imp.optimize(program, opt, train, dev)
        end
      },
      %{
        name: "miprov2",
        run: fn program, train, dev ->
          opt =
            Imp.Optimizer.MIPROv2.new(metric,
              auto: nil,
              num_candidates: 4,
              num_trials: 8,
              max_bootstrapped_demos: 4,
              max_labeled_demos: 4,
              startup_trials: 2,
              # dev/valset is 20 rows; the default minibatch_size (35) exceeds it,
              # so evaluate each trial on the full 20-row valset instead.
              minibatch: false,
              max_concurrency: 8
            )

          Imp.optimize(program, opt, train, dev)
        end
      },
      %{
        name: "copro",
        run: fn program, train, _dev ->
          opt = Imp.Optimizer.COPRO.new(metric, proposer_lm: lm, breadth: 4, depth: 2)
          Imp.optimize(program, opt, train)
        end
      },
      %{
        name: "gepa",
        run: fn program, train, dev ->
          opt =
            Imp.Optimizer.GEPA.new(gepa_metric,
              reflection_lm: lm,
              generations: 2,
              minibatch_size: 5,
              max_concurrency: 8,
              max_metric_calls: 200
            )

          Imp.optimize(program, opt, train, dev)
        end
      }
    ]

    arm_results =
      Enum.map(arms, fn arm ->
        IO.puts("\n==== ARM #{arm.name} ====")
        run_arm(arm, router, trainset, devset, testset, metric)
      end)

    artifact = %{
      "cell" => "ticket_search_optimizers",
      "campaign" => "campaign-20260718",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => @model,
      "temperature" => 0,
      "repeats_per_arm" => @repeats,
      "note_repeats_are_replicas" =>
        "temperature 0; the 2 repeats per arm are replicas that re-run the full optimize+score loop with a cleared cache each time",
      "dataset" => %{
        "path" => @dataset_relative,
        "sha256" => data_sha,
        "train" => length(trainset),
        "dev" => length(devset),
        "test" => length(testset)
      },
      "split" => %{
        "train_indices" => Enum.to_list(0..(length(trainset) - 1)),
        "dev_indices" => Enum.to_list(0..(length(devset) - 1)),
        "test_indices" => Enum.to_list(0..(length(testset) - 1)),
        "provenance" =>
          "pre-split in priv/tutorial/support_tickets.json (train/dev/test arrays); indices are positional within each array"
      },
      "controls" => %{
        "held_out_test_scored_once_per_arm_repeat" => true,
        "test_never_used_for_selection" => true,
        "optimizers_see" => "train (and dev where the API requires validation) only",
        "cache_cleared_before_each_repeat" => true,
        "cost_estimate" =>
          "cost_usd_est is APPROXIMATE from summed held-out eval token usage at #{@usd_per_m_input}/1M input + #{@usd_per_m_output}/1M output USD; live-call truth is cache misses; compile-phase tokens NOT captured"
      },
      "configuration" => %{
        "signature" => "ticket -> team: enum[atlas,harbor,beacon,quill]",
        "adapter" => "Imp.Adapter.JSON",
        "json_retries" => 1,
        "metric" => "Imp.exact_match(:team)",
        "gepa_metric" => "score 0|1 + feedback naming expected squad + charter reminder"
      },
      "reference_committed" => %{
        "zero_shot" => "0.25-0.30",
        "labeled_fewshot_k8" => "0.85",
        "source" => "context packet + docs/TUTORIAL_TICKET_ROUTING.md"
      },
      "arms" => arm_results
    }

    File.mkdir_p!(@out_dir)
    bytes = Jason.encode!(artifact, pretty: true) <> "\n"
    path = Path.join(@out_dir, @out_file)
    File.write!(path, bytes)
    IO.puts("\nartifact: #{path}")

    # Compact summary to stdout for the operator.
    IO.puts("\n==== SUMMARY ====")

    Enum.each(arm_results, fn a ->
      IO.puts(
        "#{String.pad_trailing(a["name"], 22)} status=#{a["status"]} mean=#{a["mean"]} scores=#{inspect(a["scores"])}"
      )
    end)
  end

  defp run_arm(arm, router, trainset, devset, testset, metric) do
    repeats =
      for r <- 1..@repeats do
        IO.puts("  -- repeat #{r}/#{@repeats}")
        Imp.Cache.clear()
        Imp.Cache.reset_stats()

        t0 = System.monotonic_time(:millisecond)

        result =
          try do
            compiled = arm.run.(router, trainset, devset)

            eval =
              Imp.evaluate(compiled, testset, metric, max_concurrency: 8, timeout: 60_000)

            row_scores = Enum.map(eval.rows, &(&1[:score] * 1.0))
            {:ok, compiled, eval, row_scores}
          rescue
            e ->
              {:error, Exception.format(:error, e, __STACKTRACE__)}
          catch
            kind, reason ->
              {:error, Exception.format(kind, reason, __STACKTRACE__)}
          end

        duration_ms = System.monotonic_time(:millisecond) - t0
        cache_stats = Imp.Cache.stats()
        misses = Map.get(cache_stats, :misses, 0)
        bypasses = Map.get(cache_stats, :bypasses, 0)

        case result do
          {:ok, compiled, eval, row_scores} ->
            usage = usage_from_result(eval)
            cost = estimate_cost(usage)
            inspected = inspect_compiled(compiled)

            IO.puts(
              "     score=#{eval.score} misses=#{misses} bypasses=#{bypasses} " <>
                "demos=#{inspected.demo_count} dur=#{duration_ms}ms errors=#{length(eval.errors)}"
            )

            %{
              status: :ok,
              score: eval.score,
              row_scores: row_scores,
              errors: length(eval.errors),
              error_samples: eval.errors |> Enum.take(3) |> Enum.map(&inspect/1),
              duration_ms: duration_ms,
              cache: %{misses: misses, bypasses: bypasses, hits: Map.get(cache_stats, :hits, 0)},
              usage: usage,
              cost_usd_est: cost,
              compiled: inspected
            }

          {:error, message} ->
            IO.puts("     ERROR: #{message |> String.split("\n") |> List.first()}")

            %{
              status: :error,
              error: message,
              duration_ms: duration_ms,
              cache: %{misses: misses, bypasses: bypasses, hits: Map.get(cache_stats, :hits, 0)}
            }
        end
      end

    oks = Enum.filter(repeats, &(&1.status == :ok))
    scores = Enum.map(oks, & &1.score)

    status =
      cond do
        oks == [] -> "error"
        length(oks) < @repeats -> "partial"
        true -> "ok"
      end

    mean = if scores == [], do: nil, else: Float.round(Enum.sum(scores) / length(scores), 4)

    %{
      "name" => arm.name,
      "status" => status,
      "mean" => mean,
      "scores" => scores,
      "row_scores" => Enum.map(oks, & &1.row_scores),
      "wall_seconds" =>
        (repeats |> Enum.map(& &1.duration_ms) |> Enum.sum()) / 1000.0,
      "cost_usd_est" =>
        Float.round((oks |> Enum.map(&(&1[:cost_usd_est] || 0.0)) |> Enum.sum()) * 1.0, 6),
      "cache_misses_total" => repeats |> Enum.map(&get_in(&1, [:cache, :misses])) |> Enum.sum(),
      "errors" => repeats |> Enum.map(&Map.get(&1, :error)) |> Enum.reject(&is_nil/1),
      "compiled_inspection" =>
        oks |> Enum.map(&Map.get(&1, :compiled)) |> Enum.take(1),
      "eval_error_samples" =>
        oks |> Enum.flat_map(&Map.get(&1, :error_samples, [])) |> Enum.take(3),
      "repeats_detail" =>
        Enum.map(repeats, fn rep ->
          rep
          |> Map.take([:status, :score, :duration_ms, :cache, :cost_usd_est, :errors])
          |> Map.new(fn {k, v} -> {Atom.to_string(k), stringify(v)} end)
        end)
    }
  end

  # ---- inspection of what an optimizer compiled ----
  defp inspect_compiled(program) do
    predictors =
      try do
        Imp.ProgramParameters.predictors(program)
      rescue
        _ -> []
      end

    entries =
      Enum.map(predictors, fn %{name: name, predictor: p} ->
        demos = Map.get(p, :demos, [])
        sig = Map.get(p, :signature)
        instr = if sig, do: Map.get(sig, :instructions), else: nil

        %{
          "predictor" => to_string(name),
          "demo_count" => length(demos),
          "instruction" => instr,
          "demo_teams" =>
            Enum.map(demos, fn d ->
              try do
                to_string(Imp.Example.get(d, :team))
              rescue
                _ -> nil
              end
            end),
          "demo_tickets_preview" =>
            demos
            |> Enum.take(8)
            |> Enum.map(fn d ->
              try do
                Imp.Example.get(d, :ticket)
              rescue
                _ -> nil
              end
            end)
        }
      end)

    total_demos = entries |> Enum.map(& &1["demo_count"]) |> Enum.sum()
    %{demo_count: total_demos, predictors: entries}
  end

  # ---- usage / cost ----
  defp usage_from_result(result) do
    usages =
      result.rows
      |> Enum.flat_map(fn row -> row[:prediction] |> collect_usage_maps() |> Enum.uniq() end)

    %{
      "requests_with_usage" => length(usages),
      "input_tokens" => sum_field(usages, [:input_tokens, "input_tokens"]),
      "output_tokens" => sum_field(usages, [:output_tokens, "output_tokens"]),
      "total_tokens" => sum_field(usages, [:total_tokens, "total_tokens"])
    }
  end

  defp estimate_cost(usage) do
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)

    (input / 1_000_000 * @usd_per_m_input + output / 1_000_000 * @usd_per_m_output)
    |> Float.round(6)
  end

  defp collect_usage_maps(nil), do: []

  defp collect_usage_maps(%_struct{} = struct),
    do: struct |> Map.from_struct() |> collect_usage_maps()

  defp collect_usage_maps(map) when is_map(map) do
    own = if usage_map?(map), do: [map], else: []
    own ++ Enum.flat_map(Map.values(map), &collect_usage_maps/1)
  end

  defp collect_usage_maps(list) when is_list(list),
    do: Enum.flat_map(list, &collect_usage_maps/1)

  defp collect_usage_maps(_other), do: []

  defp usage_map?(map) do
    Enum.any?([:input_tokens, "input_tokens"], &Map.has_key?(map, &1)) and
      Enum.any?([:output_tokens, "output_tokens"], &Map.has_key?(map, &1))
  end

  defp sum_field(maps, keys) do
    maps
    |> Enum.map(fn map ->
      keys
      |> Enum.find_value(0, fn key ->
        case Map.get(map, key) do
          value when is_number(value) -> value
          _ -> nil
        end
      end)
    end)
    |> Enum.sum()
  end

  # ---- helpers ----
  defp to_examples(rows) do
    for %{"ticket" => ticket, "team" => team} <- rows do
      Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
    end
  end

  defp normalize(nil), do: ""
  defp normalize(v), do: v |> to_string() |> String.trim() |> String.downcase()

  defp stringify(v) when is_map(v) and not is_struct(v),
    do: Map.new(v, fn {k, val} -> {to_string(k), val} end)

  defp stringify(v), do: v

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

TicketSearchOptimizers.main()
