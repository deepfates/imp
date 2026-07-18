# Campaign cell: gsm8k_react_calculator
#
# Question: do TOOLS help on real GSM8K data, through Imp's ReAct loop? Does the
# tool loop even RUN live on real input, and does react-with-calculator beat
# bare chain-of-thought?
#
# Split law (shared with gsm8k_cot cell): data file
#   benchmarks/runs/campaign-20260718/data/gsm8k.json
#   TEST  = rows 80..119 (40 held-out rows), scored once per arm-repeat, never
#           used for selection.
#   TRAIN = rows 0..59 (available for demos).
# Split indices + sha256 of the data file are recorded in the artifact BEFORE
# any arm runs.
#
# ARMS (2 temp-0 replica repeats each, test-40):
#   1. react_zero_shot        : Imp.react("question -> answer", [calc], ...)
#   2. react_labeled_fewshot  : same react compiled with LabeledFewShot(k: 2)
#   3. cot_zero_shot          : plain Imp.chain_of_thought("question -> answer")
#      (bare-CoT comparison anchor, no tools)
#
# The in-BEAM cache is cleared + stats reset before EVERY arm-repeat, and the
# per-arm-repeat cache stats are recorded, so each score is genuinely live.
# We do NOT modify lib/, test/, or any committed file; all writes land under
# benchmarks/runs/campaign-20260718/.

defmodule GSM8KReactCalculator do
  @model "openai:gpt-5.4-mini"
  @data_relative "benchmarks/runs/campaign-20260718/data/gsm8k.json"
  @out_path "benchmarks/runs/campaign-20260718/gsm8k_react_calculator-result.json"
  @repeats 2
  @test_range 80..119
  @train_range 0..59
  @fewshot_k 2
  @max_iters 6
  # Hard ceiling per arm-repeat. A stall past this is recorded as a :timeout
  # error and the cell moves on, instead of hanging (honors the campaign's
  # "kill a run that stalls" rule).
  @repeat_timeout_ms 300_000
  # Assumed pricing for cost estimate only (gpt-*-mini class); clearly-labeled
  # assumption, NOT a provider quote. USD per 1M tokens.
  @price_in_per_m 0.15
  @price_out_per_m 0.60

  # ----------------------------------------------------------------------------
  # Shared numeric normalization + metric (written here so the cell is
  # self-contained and uses the SAME logic the gsm8k_cot cell would).
  # ----------------------------------------------------------------------------

  # This is the SAME normalization the gsm8k_cot cell uses, copied verbatim so
  # arm 3 (cot_zero_shot) is a faithful comparison anchor and the metric is
  # provably identical across cells: strip $ , % and whitespace, take the LAST
  # number-like token, drop a trailing .0, round to 6 decimals. Returns :error
  # when no number is present so a garbage prediction never spuriously matches.
  def normalize_number(nil), do: :error

  def normalize_number(value) when is_number(value), do: normalize_number(to_string(value))

  def normalize_number(text) when is_binary(text) do
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

  # metric: 1.0 when normalized gold == normalized predicted answer, else 0.0
  def numeric_metric do
    fn example, prediction ->
      gold = example |> Imp.Example.get(:answer) |> normalize_number()
      pred = prediction |> Imp.Prediction.get(:answer) |> normalize_number()

      if gold != :error and pred != :error and gold == pred, do: 1.0, else: 0.0
    end
  end

  # ----------------------------------------------------------------------------
  # Safe calculator: recursive-descent parser over + - * / and parentheses on
  # decimal numbers, with unary minus. No Code.eval, no atom creation. Returns
  # {:ok, number} | {:error, reason}.
  # ----------------------------------------------------------------------------

  defmodule Calc do
    def eval(expr) when is_binary(expr) do
      with {:ok, tokens} <- tokenize(expr),
           {value, []} <- expr_p(tokens) do
        {:ok, value}
      else
        {_value, rest} when is_list(rest) -> {:error, {:trailing_tokens, rest}}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end

    def eval(other), do: {:error, {:not_a_string, other}}

    # --- tokenizer ---
    defp tokenize(str), do: tokenize(String.trim(str), [])

    defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

    defp tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\t, ?\n, ?\r],
      do: tokenize(rest, acc)

    defp tokenize(<<c, rest::binary>>, acc) when c in [?+, ?-, ?*, ?/, ?(, ?)],
      do: tokenize(rest, [{:op, <<c>>} | acc])

    defp tokenize(<<c, _::binary>> = str, acc) when (c >= ?0 and c <= ?9) or c == ?. do
      case Regex.run(~r/^\d*\.?\d+/, str) do
        [num] ->
          {value, ""} = Float.parse(ensure_float(num))
          rest = binary_part(str, byte_size(num), byte_size(str) - byte_size(num))
          tokenize(rest, [{:num, value} | acc])

        _ ->
          {:error, {:bad_number, str}}
      end
    end

    defp tokenize(<<c, _::binary>>, _acc), do: {:error, {:unexpected_char, <<c>>}}

    defp ensure_float("." <> _ = s), do: "0" <> s
    defp ensure_float(s), do: s

    # --- grammar: expr = term (('+'|'-') term)* ---
    defp expr_p(tokens) do
      {left, rest} = term_p(tokens)
      expr_p(left, rest)
    end

    defp expr_p(left, [{:op, "+"} | rest]) do
      {right, rest2} = term_p(rest)
      expr_p(left + right, rest2)
    end

    defp expr_p(left, [{:op, "-"} | rest]) do
      {right, rest2} = term_p(rest)
      expr_p(left - right, rest2)
    end

    defp expr_p(left, rest), do: {left, rest}

    # term = factor (('*'|'/') factor)*
    defp term_p(tokens) do
      {left, rest} = factor_p(tokens)
      term_p(left, rest)
    end

    defp term_p(left, [{:op, "*"} | rest]) do
      {right, rest2} = factor_p(rest)
      term_p(left * right, rest2)
    end

    defp term_p(left, [{:op, "/"} | rest]) do
      {right, rest2} = factor_p(rest)
      term_p(left / right, rest2)
    end

    defp term_p(left, rest), do: {left, rest}

    # factor = number | '(' expr ')' | '-' factor | '+' factor
    defp factor_p([{:num, n} | rest]), do: {n, rest}

    defp factor_p([{:op, "("} | rest]) do
      {value, rest2} = expr_p(rest)

      case rest2 do
        [{:op, ")"} | rest3] -> {value, rest3}
        _ -> throw({:unbalanced_parens, rest2})
      end
    end

    defp factor_p([{:op, "-"} | rest]) do
      {value, rest2} = factor_p(rest)
      {-value, rest2}
    end

    defp factor_p([{:op, "+"} | rest]), do: factor_p(rest)

    defp factor_p(other), do: throw({:unexpected_tokens, other})
  end

  # ----------------------------------------------------------------------------
  # Data
  # ----------------------------------------------------------------------------

  defp load_rows do
    bytes = File.read!(@data_relative)
    %{"rows" => rows} = Jason.decode!(bytes)
    {rows, sha256(bytes)}
  end

  defp slice(rows, range) do
    for i <- range, row = Enum.at(rows, i), not is_nil(row) do
      {i, row}
    end
  end

  defp to_examples(indexed) do
    for {_i, %{"question" => q, "final_answer" => a}} <- indexed do
      Imp.example(question: q, answer: to_string(a)) |> Imp.with_inputs(:question)
    end
  end

  # ----------------------------------------------------------------------------
  # Run
  # ----------------------------------------------------------------------------

  # Prove the two moving parts that don't need an LM BEFORE spending: the
  # recursive-descent calculator and the numeric metric. A bug here would
  # silently poison every arm, so fail loud and early.
  defp preflight! do
    IO.puts("== preflight (no LM spend) ==")

    calc_checks = [
      {"(16-3-4)*2", "18"},
      {"3 + 4 * 2", "11"},
      {"10 / 4", "2.5"},
      {"-(2+3)", "-5"},
      {"2 * (3 + (4 - 1))", "12"}
    ]

    for {expr, want} <- calc_checks do
      got = run_calc(%{"expression" => expr})
      IO.puts("   calc #{expr} = #{got} (want #{want})")
      unless got == want, do: raise("calc preflight FAILED: #{expr} got #{got} want #{want}")
    end

    # calculator must reject/soft-fail bad input rather than crash
    bad = run_calc(%{"expression" => "2 + ; drop table"})
    unless String.starts_with?(bad, "ERROR:"),
      do: raise("calc preflight FAILED: bad input not rejected, got #{bad}")

    IO.puts("   calc rejects garbage: #{String.slice(bad, 0, 40)}...")

    m = numeric_metric()
    ex = Imp.example(question: "q", answer: "18") |> Imp.with_inputs(:question)

    metric_checks = [
      {"exact", %{answer: "18"}, 1.0},
      {"dollar+.0", %{answer: "$18.0"}, 1.0},
      {"trailing text", %{answer: "The answer is 18."}, 1.0},
      {"wrong", %{answer: "9"}, 0.0},
      {"empty", %{answer: ""}, 0.0}
    ]

    for {name, fields, want} <- metric_checks do
      pred = Imp.prediction(Map.to_list(fields))
      got = m.(ex, pred)
      IO.puts("   metric #{name}: got #{got} want #{want}")
      unless got == want, do: raise("metric preflight FAILED: #{name} got #{got} want #{want}")
    end

    IO.puts("   preflight OK\n")
  end

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")
    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    preflight!()

    {rows, data_sha} = load_rows()
    test_indexed = slice(rows, @test_range)
    train_indexed = slice(rows, @train_range)
    testset = to_examples(test_indexed)
    trainset = to_examples(train_indexed)

    test_indices = Enum.map(test_indexed, &elem(&1, 0))
    train_indices = Enum.map(train_indexed, &elem(&1, 0))

    IO.puts(
      "loaded #{length(rows)} rows | test=#{length(testset)} (#{List.first(test_indices)}..#{List.last(test_indices)}) " <>
        "train=#{length(trainset)} | data sha256=#{String.slice(data_sha, 0, 12)}…"
    )

    metric = numeric_metric()

    calc =
      Imp.tool(
        :calc,
        "Evaluate a basic arithmetic expression over numbers using + - * / and parentheses. " <>
          "Input is a single field 'expression', e.g. {\"expression\": \"(16-3-4)*2\"}.",
        &run_calc/1,
        schema: %{
          "type" => "object",
          "properties" => %{
            "expression" => %{
              "type" => "string",
              "description" => "arithmetic expression, e.g. (16-3-4)*2"
            }
          },
          "required" => ["expression"]
        }
      )

    react =
      Imp.react("question -> answer", [calc],
        lm: lm,
        tool_policy: [:calc, :submit],
        max_iters: @max_iters
      )

    cot = Imp.chain_of_thought("question -> answer", lm: lm)

    # Arm 2: attach demos to the react program via LabeledFewShot (deterministic,
    # no LM). Record whether demos actually attached to react.
    {react_fewshot, fewshot_status} = try_labeled_fewshot(react, trainset, @fewshot_k)

    arms = [
      %{name: "react_zero_shot", program: react, kind: "react", notes: ""},
      %{
        name: "react_labeled_fewshot",
        program: react_fewshot,
        kind: "react",
        notes: fewshot_status
      },
      %{name: "cot_zero_shot", program: cot, kind: "chain_of_thought", notes: "bare CoT anchor"}
    ]

    arm_results =
      for arm <- arms do
        IO.puts("\n== ARM #{arm.name} ==")
        run_arm(arm, testset, metric)
      end

    artifact = %{
      "schema_version" => 1,
      "cell" => "gsm8k_react_calculator",
      "runner" => "benchmarks/runs/campaign-20260718/gsm8k_react_calculator.exs",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => @model,
      "temperature" => 0,
      "repeats_are" => "temperature-0 replicas",
      "question" =>
        "Does Imp's ReAct tool loop run live on real GSM8K input, and does react+calculator beat bare chain-of-thought?",
      "dataset" => %{
        "path" => @data_relative,
        "sha256" => data_sha,
        "total_rows" => length(rows),
        "test_indices" => test_indices,
        "train_indices" => train_indices,
        "test_n" => length(testset),
        "train_n" => length(trainset),
        "split_law" => "TEST rows 80..119 held out, scored once per arm-repeat; TRAIN rows 0..59 for demos"
      },
      "configuration" => %{
        "react_signature" => "question -> answer",
        "react_tools" => ["calc"],
        "react_tool_policy" => [":calc", ":submit"],
        "react_max_iters" => @max_iters,
        "cot_signature" => "question -> answer",
        "optimizer" => "Imp.Optimizer.LabeledFewShot",
        "fewshot_k" => @fewshot_k,
        "fewshot_status" => fewshot_status,
        "metric" => "numeric last-number match (normalized: strip $/commas, canonical number)",
        "repeats" => @repeats,
        "cache_cleared_per_arm_repeat" => true,
        "cost_price_assumption_usd_per_m" => %{
          "input" => @price_in_per_m,
          "output" => @price_out_per_m,
          "note" => "assumed rate for cost_usd_est only; NOT a provider quote"
        }
      },
      "arms" => arm_results
    }

    File.mkdir_p!(Path.dirname(@out_path))
    File.write!(@out_path, Jason.encode!(artifact, pretty: true) <> "\n")
    IO.puts("\nartifact: #{@out_path}")

    print_summary(arm_results)
  end

  # Calculator tool runner. Accepts atom or string keys from the provider.
  defp run_calc(args) do
    expr = args[:expression] || args["expression"]

    case Calc.eval(expr) do
      {:ok, value} -> canonical_result(value)
      {:error, reason} -> "ERROR: could not evaluate #{inspect(expr)} (#{inspect(reason)})"
    end
  end

  defp canonical_result(value) when is_float(value) do
    rounded = Float.round(value)

    if abs(value - rounded) < 1.0e-9 do
      rounded |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(value, [:short])
    end
  end

  defp canonical_result(value), do: to_string(value)

  defp try_labeled_fewshot(react, trainset, k) do
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: k)
    compiled = Imp.optimize(react, optimizer, trainset)

    attached =
      case Imp.ProgramAccess.predict(compiled) do
        nil -> []
        predict -> Map.get(predict, :demos, [])
      end

    if length(attached) > 0 do
      {compiled, "LabeledFewShot k=#{k} attached #{length(attached)} demos to react.react predict"}
    else
      {compiled, "WARNING: LabeledFewShot attached 0 demos to react (demos did not stick)"}
    end
  rescue
    e ->
      {react, "ERROR: LabeledFewShot on react raised #{Exception.message(e)}; arm falls back to zero-shot program"}
  end

  defp run_arm(arm, testset, metric) do
    repeats =
      for r <- 1..@repeats do
        Imp.Cache.clear()
        Imp.Cache.reset_stats()

        t0 = System.monotonic_time(:millisecond)

        task =
          Task.async(fn ->
            try do
              res = Imp.evaluate(arm.program, testset, metric, max_concurrency: 4, timeout: 120_000)
              {"ok", res, nil}
            rescue
              e -> {"error", nil, Exception.message(e)}
            catch
              kind, reason -> {"error", nil, inspect({kind, reason})}
            end
          end)

        {status, result, err} =
          case Task.yield(task, @repeat_timeout_ms) || Task.shutdown(task, :brutal_kill) do
            {:ok, value} -> value
            nil -> {"error", nil, "TIMEOUT: repeat exceeded #{@repeat_timeout_ms}ms"}
          end

        wall_ms = System.monotonic_time(:millisecond) - t0
        cache = Imp.Cache.stats()

        {row_scores, mean, errors, usage} =
          case result do
            nil ->
              {[], nil, [], zero_usage()}

            res ->
              scored =
                res.rows
                |> Enum.sort_by(& &1.index)
                |> Enum.map(&(&1.score * 1.0))

              {scored, res.score, res.errors, usage_from_result(res)}
          end

        IO.puts(
          "   repeat #{r}: status=#{status} score=#{inspect(mean)} " <>
            "wall=#{wall_ms}ms cache(hits=#{Map.get(cache, :hits, 0)},miss=#{Map.get(cache, :misses, 0)}) " <>
            "errors=#{length(errors)}#{if err, do: " EXC=#{err}", else: ""}"
        )

        %{
          "repeat" => r,
          "status" => status,
          "error" => err,
          "score" => mean,
          "row_scores" => row_scores,
          "n_scored" => length(row_scores),
          "wall_ms" => wall_ms,
          "eval_errors" => length(errors),
          "cache" => %{
            "cleared_before" => true,
            "hits" => Map.get(cache, :hits, 0),
            "misses" => Map.get(cache, :misses, 0),
            "bypasses" => Map.get(cache, :bypasses, 0)
          },
          "usage" => usage,
          "cost_usd_est" => cost_of(usage)
        }
      end

    scores = repeats |> Enum.map(& &1["score"]) |> Enum.reject(&is_nil/1)
    ok? = Enum.any?(repeats, &(&1["status"] == "ok"))

    %{
      "name" => arm.name,
      "kind" => arm.kind,
      "notes" => arm.notes,
      "status" => if(ok?, do: "ok", else: "error"),
      "repeats" => repeats,
      "mean_score" => if(scores == [], do: nil, else: Float.round(Enum.sum(scores) / length(scores), 6)),
      "scores" => scores,
      "wall_seconds_total" =>
        Float.round(Enum.sum(Enum.map(repeats, & &1["wall_ms"])) / 1000, 2),
      "cost_usd_est_total" =>
        Float.round(Enum.sum(Enum.map(repeats, & &1["cost_usd_est"])), 6)
    }
  end

  defp print_summary(arm_results) do
    IO.puts("\n===== SUMMARY =====")

    for a <- arm_results do
      IO.puts(
        "#{String.pad_trailing(a["name"], 24)} status=#{a["status"]} " <>
          "mean=#{inspect(a["mean_score"])} scores=#{inspect(a["scores"])} " <>
          "wall=#{a["wall_seconds_total"]}s cost~$#{a["cost_usd_est_total"]}"
      )
    end
  end

  # --- usage / cost ---
  defp zero_usage,
    do: %{"requests_with_usage" => 0, "input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}

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

  defp cost_of(usage) do
    inp = Map.get(usage, "input_tokens", 0)
    out = Map.get(usage, "output_tokens", 0)
    Float.round(inp / 1_000_000 * @price_in_per_m + out / 1_000_000 * @price_out_per_m, 6)
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
      Enum.find_value(keys, 0, fn key ->
        case Map.get(map, key) do
          v when is_number(v) -> v
          _ -> nil
        end
      end)
    end)
    |> Enum.sum()
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

GSM8KReactCalculator.main()
