# Campaign cell: hotpot_rag
#
# Question: does grounding through Imp's retrieval seam (Imp.memory + Imp.rag)
# beat closed-book prediction on real multi-hop QA (HotPotQA distractor)?
#
# Data: benchmarks/runs/campaign-20260718/data/hotpot.json (100 rows).
# Split IN ORDER: rows 0-39 train, 40-49 dev, 50-89 test (40 held out).
# Each row's own paragraphs (gold + distractors) form that row's retrieval
# corpus; a fresh per-row Imp.memory retriever is built for every call.
#
# Arms (2 repeats each, temp 0 => replicas, scored on the 40 held-out test rows):
#   1. no-retrieval predict "question -> answer"          (closed-book anchor)
#   2. rag zero-shot  predict "question, context -> answer" + per-row memory(k:3)
#   3. rag + LabeledFewShot(k:4) demos from train rows 0-3 (context rendered
#      from each demo's top-3 retrieval over its OWN paragraphs)
#
# Metric: Imp.extractive_qa F1 (primary) and EM, per row.
#
# Controls: data sha256 + split indices recorded before any arm runs; test set
# scored once per arm-repeat, never used for selection; Imp.Cache.clear() +
# reset_stats() before every repeat; per-repeat cache stats recorded; wall time
# and token usage recorded per arm-repeat.

defmodule HotpotRag do
  @model "openai:gpt-5.4-mini"
  @data_path "benchmarks/runs/campaign-20260718/data/hotpot.json"
  @out_path "benchmarks/runs/campaign-20260718/hotpot_rag-result.json"
  @k 3
  @demo_k 4
  @repeats 2

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    data_bytes = File.read!(@data_path)
    data_sha = :crypto.hash(:sha256, data_bytes) |> Base.encode16(case: :lower)
    rows = Jason.decode!(data_bytes)["rows"]

    # Fixed, in-order split recorded BEFORE any arm runs.
    train = Enum.slice(rows, 0, 40)
    _dev = Enum.slice(rows, 40, 10)
    test = Enum.slice(rows, 50, 40)

    split = %{
      "train_indices" => "0..39",
      "dev_indices" => "40..49",
      "test_indices" => "50..89",
      "train_n" => length(train),
      "dev_n" => 10,
      "test_n" => length(test),
      "data_sha256" => data_sha
    }

    IO.puts("data sha256 #{data_sha}; train #{length(train)} test #{length(test)}")

    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    closed_book = Imp.predict("question -> answer", lm: lm)
    grounded = Imp.predict("question, context -> answer", lm: lm)

    # Arm 3: build LabeledFewShot demos from the first @demo_k train rows.
    # Each demo's context is rendered from the top-@k retrieval over that demo's
    # OWN paragraph corpus (gold labels are not present in this reduced dataset,
    # so we render context the same way the program sees it at test time).
    demos =
      train
      |> Enum.take(@demo_k)
      |> Enum.map(fn row ->
        ctx = render_context_for(row)

        Imp.example(question: row["question"], context: ctx, answer: row["answer"])
        |> Imp.with_inputs([:question, :context])
      end)

    compiled_fewshot =
      Imp.optimize(grounded, Imp.Optimizer.LabeledFewShot.new(k: @demo_k), demos)

    demo_report = Imp.Optimizer.Report.fetch(compiled_fewshot)
    IO.puts("arm3 demos attached: #{inspect(demo_report && Map.get(demo_report, :candidate_count))}")

    arms = [
      {"no_retrieval_closed_book",
       fn _row -> closed_book end, [:question]},
      {"rag_zero_shot",
       fn row -> Imp.rag(grounded, row_retriever(row), k: @k, query_field: :question) end,
       [:question]},
      {"rag_labeled_fewshot_k4",
       fn row -> Imp.rag(compiled_fewshot, row_retriever(row), k: @k, query_field: :question) end,
       [:question]}
    ]

    arm_results =
      for {name, build, _inputs} <- arms do
        IO.puts("\n== arm #{name}")
        run_arm(name, build, test)
      end

    artifact = %{
      "cell" => "hotpot_rag",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => @model,
      "temperature" => 0,
      "repeats_note" => "temp 0 repeats are replicas",
      "metric" => "Imp.extractive_qa: F1 primary, EM secondary (per row)",
      "retrieval" => %{
        "retriever" => "Imp.memory(row_docs, k: #{@k}) per row; token-overlap",
        "docs" => "%{id: paragraph.title, text: paragraph.text}",
        "rag" => "Imp.rag(program, retriever, k: #{@k}, query_field: :question)"
      },
      "split" => split,
      "arms" => arm_results
    }

    File.write!(@out_path, Jason.encode!(artifact, pretty: true) <> "\n")
    IO.puts("\nartifact: #{@out_path}")

    # Compact console summary.
    for arm <- arm_results do
      means = arm["repeats"] |> Enum.map(& &1["mean_f1"]) |> Enum.map(&Float.round(&1, 4))
      IO.puts("#{arm["name"]}: f1 means #{inspect(means)} errors #{arm["total_errors"]}")
    end
  end

  # Build a fresh per-row memory retriever from that row's paragraph corpus.
  defp row_retriever(row) do
    docs = Enum.map(row["paragraphs"], fn p -> %{id: p["title"], text: p["text"]} end)
    Imp.memory(docs, k: @k)
  end

  # Render the top-@k retrieval context for a row over its OWN corpus.
  defp render_context_for(row) do
    retriever = row_retriever(row)
    {:ok, docs} = Imp.Retrieve.retrieve(retriever, row["question"], k: @k)
    docs |> Enum.map(&Map.get(&1, :text, "")) |> Enum.join("\n\n")
  end

  defp run_arm(name, build, test) do
    repeats =
      for r <- 1..@repeats do
        Imp.Cache.clear()
        Imp.Cache.reset_stats()

        t0 = System.monotonic_time(:millisecond)

        rows =
          Enum.with_index(test)
          |> Enum.map(fn {row, idx} ->
            program = build.(row)
            gold = row["answer"]

            case Imp.call(program, %{question: row["question"]}) do
              {:ok, pred} ->
                answer = pred |> Imp.get(:answer) |> to_string()
                f1 = Imp.Metrics.f1(answer, gold)
                em = Imp.Metrics.em(answer, gold)
                usage = usage_of(pred)

                %{
                  "test_index" => 50 + idx,
                  "question" => row["question"],
                  "gold" => gold,
                  "predicted" => answer,
                  "f1" => Float.round(f1, 6),
                  "em" => em,
                  "error" => nil,
                  "usage" => usage
                }

              {:error, reason} ->
                %{
                  "test_index" => 50 + idx,
                  "question" => row["question"],
                  "gold" => gold,
                  "predicted" => nil,
                  "f1" => 0.0,
                  "em" => false,
                  "error" => inspect(reason),
                  "usage" => %{}
                }
            end
          end)

        duration_ms = System.monotonic_time(:millisecond) - t0
        cache = Imp.Cache.stats()

        f1s = Enum.map(rows, & &1["f1"])
        ems = Enum.map(rows, fn row -> if row["em"], do: 1.0, else: 0.0 end)
        errors = Enum.count(rows, &(&1["error"] != nil))
        usage = merge_usage(Enum.map(rows, & &1["usage"]))

        mean_f1 = mean(f1s)
        mean_em = mean(ems)

        IO.puts(
          "   repeat #{r}: mean_f1 #{Float.round(mean_f1, 4)} mean_em #{Float.round(mean_em, 4)} " <>
            "errors #{errors} #{duration_ms}ms cache(h#{Map.get(cache, :hits, 0)}/m#{Map.get(cache, :misses, 0)}) " <>
            "tok #{Map.get(usage, "total_tokens", 0)}"
        )

        %{
          "repeat" => r,
          "mean_f1" => mean_f1,
          "mean_em" => mean_em,
          "errors" => errors,
          "duration_ms" => duration_ms,
          "cache" => %{
            "cleared_before_run" => true,
            "hits" => Map.get(cache, :hits, 0),
            "misses" => Map.get(cache, :misses, 0),
            "bypasses" => Map.get(cache, :bypasses, 0)
          },
          "usage" => usage,
          "rows" => rows
        }
      end

    total_errors = repeats |> Enum.map(& &1["errors"]) |> Enum.sum()

    %{
      "name" => name,
      "repeats" => repeats,
      "total_errors" => total_errors
    }
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp usage_of(pred) do
    meta = Map.get(pred, :metadata, %{}) || %{}
    collect_usage_maps(meta) |> Enum.uniq() |> merge_raw_usage()
  end

  defp merge_raw_usage(usages) do
    %{
      "requests_with_usage" => length(usages),
      "input_tokens" => sum_field(usages, [:input_tokens, "input_tokens"]),
      "output_tokens" => sum_field(usages, [:output_tokens, "output_tokens"]),
      "total_tokens" => sum_field(usages, [:total_tokens, "total_tokens"])
    }
  end

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
    (Map.has_key?(map, :input_tokens) or Map.has_key?(map, "input_tokens")) and
      (Map.has_key?(map, :output_tokens) or Map.has_key?(map, "output_tokens"))
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

  defp merge_usage(usages) do
    usages = Enum.reject(usages, &(&1 == %{} or is_nil(&1)))

    %{
      "requests_with_usage" => sum_field(usages, ["requests_with_usage"]),
      "input_tokens" => sum_field(usages, ["input_tokens"]),
      "output_tokens" => sum_field(usages, ["output_tokens"]),
      "total_tokens" => sum_field(usages, ["total_tokens"])
    }
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end

HotpotRag.main()
