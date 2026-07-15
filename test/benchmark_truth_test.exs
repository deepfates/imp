defmodule BenchmarkTruthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Imp.BenchmarkTruth.Fetcher

  @fixtures Path.expand("fixtures/benchmarks", __DIR__)

  test "benchmark row instrumentation records ReqLLM tokens and provider cost" do
    key = {__MODULE__, make_ref()}

    Process.put(key, %{
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
    })

    on_exit(fn -> Process.delete(key) end)

    Imp.BenchmarkTruth.Runner.record_instrumentation(
      [:req_llm, :token_usage],
      %{tokens: %{input_tokens: 123, output_tokens: 45}, total_cost: 0.0067},
      %{},
      {self(), key}
    )

    assert Process.get(key) |> Map.take(~w(usage_events input_tokens output_tokens usd)) == %{
             "usage_events" => 1,
             "input_tokens" => 123,
             "output_tokens" => 45,
             "usd" => 0.0067
           }
  end

  test "benchmark row instrumentation decomposes ReqLLM and Finch transport time" do
    key = {__MODULE__, make_ref()}
    owner = self()
    Process.put(key, transport_instrumentation())
    on_exit(fn -> Process.delete(key) end)

    events = [
      {[:req_llm, :request, :stop], 120_000_000},
      {[:finch, :request, :stop], 110_000_000},
      {[:finch, :queue, :stop], 20_000_000},
      {[:finch, :connect, :stop], 10_000_000},
      {[:finch, :send, :stop], 5_000_000},
      {[:finch, :recv, :stop], 75_000_000},
      {[:finch, :request, :exception], 2_000_000}
    ]

    Enum.each(events, fn {event, duration} ->
      Imp.BenchmarkTruth.Runner.record_instrumentation(
        event,
        %{duration: System.convert_time_unit(duration, :nanosecond, :native)},
        %{},
        {owner, key}
      )
    end)

    stats = Process.get(key)
    assert stats["req_llm_requests"] == 1
    assert stats["req_llm_request_duration_ms"] == 120.0
    assert stats["finch_requests"] == 2
    assert stats["finch_request_duration_ms"] == 112.0
    assert stats["finch_queue_duration_ms"] == 20.0
    assert stats["finch_connect_duration_ms"] == 10.0
    assert stats["finch_send_duration_ms"] == 5.0
    assert stats["finch_receive_duration_ms"] == 75.0

    task =
      Task.async(fn ->
        Imp.BenchmarkTruth.Runner.record_instrumentation(
          [:finch, :queue, :stop],
          %{duration: System.convert_time_unit(1, :second, :native)},
          %{},
          {owner, key}
        )
      end)

    Task.await(task)
    assert Process.get(key)["finch_queue_events"] == 1
  end

  defp transport_instrumentation do
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

  test "RLM campaign plan task emits exact bounded jobs without execution" do
    manifest = hermetic_rlm_manifest!()

    output =
      capture_io(fn ->
        Mix.Task.reenable("imp.benchmark.rlm_campaign")

        Mix.Tasks.Imp.Benchmark.RlmCampaign.run([
          "--plan",
          "--manifest",
          manifest,
          "--family",
          "oolong",
          "--approach",
          "direct,rlm",
          "--runtime",
          "both",
          "--sample-limit",
          "1"
        ])
      end)

    plan = Jason.decode!(output)
    assert plan["provider_calls"] == 0
    assert plan["evidence_tier"] == "t2_live_sample"
    assert plan["job_count"] == 4

    assert Enum.map(plan["jobs"], & &1["key"]) == [
             "imp:direct:oolong:17000206",
             "imp:rlm:oolong:17000206",
             "dspy:direct:oolong:17000206",
             "dspy:rlm:oolong:17000206"
           ]
  end

  defp hermetic_rlm_manifest! do
    root = Path.join(System.tmp_dir!(), "imp-rlm-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    canonical =
      "benchmarks/config/rlm-paper-protocol-v3.json"
      |> File.read!()
      |> Jason.decode!()

    spec = canonical["datasets"]["oolong"]

    rows =
      Enum.map(0..49, fn index ->
        %{
          "id" => if(index == 0, do: "17000206", else: "synthetic-#{index}"),
          "source" => spec["source"],
          "revision" => spec["revision"],
          "split" => spec["split"],
          "context" => ["yes"],
          "question" => "answer?",
          "answer" => "yes"
        }
      end)

    dataset_path = Path.join(root, "oolong.jsonl")
    File.write!(dataset_path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")

    dataset =
      spec
      |> Map.put("path", dataset_path)
      |> Map.put("sha256", sha256_file(dataset_path))
      |> Map.put("sample_count", 50)
      |> Map.put("sample_ids", Enum.map(rows, & &1["id"]))

    manifest = put_in(canonical, ["datasets", "oolong"], dataset)
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    manifest_path
  end

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defmodule ReqLLMStub do
    def generate_text(_model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:benchmark_req_llm_generate, length(messages)})

      {:ok,
       %ReqLLM.Response{
         id: "bench_resp_1",
         model: "gpt-test",
         context: ReqLLM.Context.new(messages),
         message:
           ReqLLM.Context.assistant("""
           [[ ## reasoning ## ]]
           Janet sells nine eggs at two dollars each.

           [[ ## answer ## ]]
           18

           [[ ## completed ## ]]
           """),
         object: nil
       }}
    end
  end

  test "parity runner detects first-side API errors before paired dispatch" do
    clean = %{"tasks" => [%{"task" => "gsm8k", "errors" => []}]}
    counted = %{"tasks" => [%{"task" => "gsm8k", "errors" => 2}]}
    listed = %{"tasks" => [%{"task" => "hotpotqa", "errors" => [%{"reason" => "400"}]}]}

    refute Mix.Tasks.Imp.Benchmark.Parity.runner_errors?(clean)
    assert Mix.Tasks.Imp.Benchmark.Parity.runner_errors?(counted)
    assert Mix.Tasks.Imp.Benchmark.Parity.runner_errors?(listed)
    assert Mix.Tasks.Imp.Benchmark.Parity.runner_errors?(%{"tasks" => [%{"errors" => :bad}]})
    assert Mix.Tasks.Imp.Benchmark.Parity.runner_errors?(:invalid_report)
  end

  test "fetcher normalizes HuggingFace rows and writes manifests" do
    out_dir = tmp_dir("fetch")

    body =
      Jason.encode!(%{
        "rows" => [
          %{
            "row" => %{
              "question" => "What is 2+2?",
              "answer" => "Compute 2+2. #### 4"
            }
          }
        ]
      })

    [result] =
      Imp.BenchmarkTruth.fetch(["gsm8k"],
        out_dir: out_dir,
        length: 1,
        page_delay_ms: 0,
        transport: fn _url -> {:ok, body} end
      )

    assert File.exists?(result.data_path)
    assert File.exists?(result.manifest_path)

    assert %{"rows" => 1, "task" => "gsm8k", "sha256" => sha} =
             Jason.decode!(File.read!(result.manifest_path))

    assert byte_size(sha) == 64
    assert [%{"canonical_answer" => "4"}] = result.data_path |> File.read!() |> read_jsonl()
  end

  test "fetcher writes deterministic local classification and tabular samples" do
    out_dir = tmp_dir("fetch-local-classification")

    results =
      Imp.BenchmarkTruth.fetch(["colors", "iris", "iris_typo", "heart_disease"],
        out_dir: out_dir,
        length: :full
      )

    assert Enum.map(results, & &1.task) == ["colors", "iris", "iris_typo", "heart_disease"]

    colors = Enum.find(results, &(&1.task == "colors"))
    manifest = Jason.decode!(File.read!(colors.manifest_path))
    rows = colors.data_path |> File.read!() |> read_jsonl()

    assert manifest["source"] == "local-fixture"
    assert manifest["input_keys"] == ["input"]
    assert manifest["label_key"] == "label"
    assert manifest["rows"] == 6
    assert [%{"input" => "red", "label" => "warm", "source_task" => "colors"} | _] = rows

    iris = Enum.find(results, &(&1.task == "iris"))

    assert [%{"features" => features, "label" => "setosa"} | _] =
             iris.data_path |> File.read!() |> read_jsonl()

    assert features =~ "sepal_length"
  end

  test "fetcher writes retrieval and claim verification corpora with query manifests" do
    out_dir = tmp_dir("fetch-local-retrieval")

    results =
      Imp.BenchmarkTruth.fetch(["retrieval_qa", "claim_verification"],
        out_dir: out_dir,
        length: :full
      )

    assert Enum.map(results, & &1.task) == ["retrieval_qa", "claim_verification"]

    retrieval = Enum.find(results, &(&1.task == "retrieval_qa"))
    manifest = Jason.decode!(File.read!(retrieval.manifest_path))
    rows = retrieval.data_path |> File.read!() |> read_jsonl()
    corpus = manifest["corpus_path"] |> File.read!() |> read_jsonl()

    assert manifest["source"] == "local-fixture"
    assert manifest["input_keys"] == ["question"]
    assert manifest["label_key"] == "answer"
    assert manifest["corpus_rows"] == 4
    assert byte_size(manifest["corpus_sha256"]) == 64

    assert [%{"question" => question, "answer" => "Paris", "evidence_ids" => ["city-france"]} | _] =
             rows

    assert question =~ "France"
    assert Enum.any?(corpus, &(&1["id"] == "city-france" and &1["text"] =~ "Paris"))

    claims = Enum.find(results, &(&1.task == "claim_verification"))
    claim_manifest = Jason.decode!(File.read!(claims.manifest_path))

    assert claim_manifest["input_keys"] == ["claim"]
    assert claim_manifest["label_key"] == "label"
    assert File.exists?(claim_manifest["corpus_path"])
  end

  test "fetcher writes deterministic composition orchestration samples" do
    out_dir = tmp_dir("fetch-local-composition")

    [result] =
      Imp.BenchmarkTruth.fetch(["composition_orchestration"],
        out_dir: out_dir,
        length: :full
      )

    manifest = Jason.decode!(File.read!(result.manifest_path))
    rows = result.data_path |> File.read!() |> read_jsonl()

    assert result.task == "composition_orchestration"
    assert manifest["source"] == "local-fixture"
    assert manifest["input_keys"] == ["question"]
    assert manifest["label_key"] == "answer"
    assert manifest["rows"] == 3

    assert [
             %{
               "question" => question,
               "answer" => "Paris",
               "source_task" => "composition_orchestration"
             }
             | _
           ] = rows

    assert question =~ "France"
  end

  test "fetcher writes IFBench-style and hard-math samples with fixed manifests" do
    out_dir = tmp_dir("fetch-local-ifbench-hard-math")

    [ifbench, hard_math] =
      Imp.BenchmarkTruth.fetch(["ifbench_instruction_following", "hard_math"],
        out_dir: out_dir,
        length: :full
      )

    ifbench_manifest = Jason.decode!(File.read!(ifbench.manifest_path))
    ifbench_rows = ifbench.data_path |> File.read!() |> read_jsonl()

    assert ifbench.task == "ifbench_instruction_following"
    assert ifbench_manifest["source"] == "local-fixture"
    assert ifbench_manifest["input_keys"] == ["instruction"]
    assert ifbench_manifest["label_key"] == "answer"
    assert ifbench_manifest["rows"] == 3
    assert [%{"constraints" => [%{"type" => "exact", "value" => "OK"} | _]} | _] = ifbench_rows

    hard_math_manifest = Jason.decode!(File.read!(hard_math.manifest_path))
    hard_math_rows = hard_math.data_path |> File.read!() |> read_jsonl()

    assert hard_math.task == "hard_math"
    assert hard_math_manifest["source"] == "local-fixture"
    assert hard_math_manifest["input_keys"] == ["problem"]
    assert hard_math_manifest["label_key"] == "answer"
    assert hard_math_manifest["rows"] == 3
    assert [%{"problem" => problem, "canonical_answer" => "5"} | _] = hard_math_rows
    assert problem =~ "7x"
  end

  test "fetcher paginates full-size requests and records source pages" do
    out_dir = tmp_dir("fetch-pages")
    parent = self()

    [result] =
      Imp.BenchmarkTruth.fetch(["gsm8k"],
        out_dir: out_dir,
        length: 101,
        page_delay_ms: 0,
        transport: fn url ->
          send(parent, {:fetched, URI.decode(url)})

          rows =
            if String.contains?(url, "offset=0") do
              Enum.map(1..100, &gsm8k_hf_row/1)
            else
              [gsm8k_hf_row(101)]
            end

          {:ok, Jason.encode!(%{"rows" => rows})}
        end
      )

    manifest = Jason.decode!(File.read!(result.manifest_path))
    rows = result.data_path |> File.read!() |> read_jsonl()

    assert manifest["requested_length"] == 101
    assert manifest["rows"] == 101
    assert length(manifest["source_urls"]) == 2
    assert length(rows) == 101
    assert_received {:fetched, url}
    assert url =~ "length=100"
    assert_received {:fetched, url}
    assert url =~ "offset=100"
  end

  test "HotPotQA canonical fetch uses the context-grounded distractor config" do
    assert %{config: "distractor"} = Fetcher.canonical_specs()["hotpotqa"]
  end

  test "benchmark prompt contract has one Elixir source of truth" do
    assert Imp.BenchmarkTruth.current_prompt_contract() == current_prompt_contract()
    assert Imp.BenchmarkTruth.Contract.hotpotqa_instruction() =~ "canonical exact answer span"
    assert Imp.BenchmarkTruth.Contract.hotpotqa_instruction() =~ "Do not abbreviate locations"
  end

  test "HotPotQA normalization flattens title/sentence context" do
    row = %{
      "id" => "x",
      "question" => "q",
      "answer" => "a",
      "context" => %{"title" => ["One"], "sentences" => [["Alpha.", "Beta."]]},
      "supporting_facts" => %{}
    }

    assert %{"context" => "One: Alpha. Beta."} = Fetcher.normalize_hotpotqa(row)
  end

  test "fixture benchmark truth runner evaluates GSM8K and HotPotQA and writes report" do
    out_dir = tmp_dir("results")

    result =
      Imp.BenchmarkTruth.run(
        tasks: [
          gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl"),
          hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")
        ],
        out_dir: out_dir,
        max_examples: 2
      )

    assert File.exists?(result.out_path)
    assert result.report["aggregate_score"] == 1.0
    assert Enum.map(result.report["tasks"], & &1["task"]) == ["gsm8k", "hotpotqa"]
    assert Enum.all?(result.report["tasks"], &(&1["score"] == 1.0))

    assert Enum.all?(result.report["tasks"], fn task ->
             task["optimizer_comparisons"]
             |> Enum.map(& &1["optimizer"])
             |> Enum.sort() ==
               ["BootstrapFewShot", "COPRO", "GEPA", "LabeledFewShot", "MIPROv2", "SIMBA"]
           end)

    assert %{"schema_version" => 1, "tasks" => [_ | _]} =
             Jason.decode!(File.read!(result.out_path))
  end

  test "fixture benchmark truth runner evaluates local classification tasks with F1 reports" do
    out_dir = tmp_dir("classification-results")

    [colors] =
      Imp.BenchmarkTruth.fetch(["colors"],
        out_dir: out_dir,
        length: :full
      )

    result =
      Imp.BenchmarkTruth.run(
        tasks: [colors: colors.data_path],
        out_dir: out_dir,
        max_examples: 6,
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    assert task["task"] == "colors"
    assert task["score"] == 1.0
    assert task["aggregate_metrics"]["accuracy"] == 1.0
    assert task["aggregate_metrics"]["macro_f1"] == 1.0
    assert task["aggregate_metrics"]["micro_f1"] == 1.0
    assert task["aggregate_metrics"]["weighted_f1"] == 1.0
    assert Map.keys(task["aggregate_metrics"]["labels"]) == ["cool", "warm"]
    assert Enum.all?(task["rows"], & &1["passed"])
    assert File.exists?(result.out_path)
  end

  test "fixture benchmark truth runner evaluates retrieval and claim tasks with evidence recall" do
    out_dir = tmp_dir("retrieval-results")

    [retrieval, claims] =
      Imp.BenchmarkTruth.fetch(["retrieval_qa", "claim_verification"],
        out_dir: out_dir,
        length: :full
      )

    result =
      Imp.BenchmarkTruth.run(
        tasks: [retrieval_qa: retrieval.data_path, claim_verification: claims.data_path],
        out_dir: out_dir,
        max_examples: 3,
        optimizer_comparisons: false
      )

    assert result.report["aggregate_score"] == 1.0

    by_task = Map.new(result.report["tasks"], &{&1["task"], &1})
    retrieval_task = by_task["retrieval_qa"]
    claim_task = by_task["claim_verification"]

    assert retrieval_task["aggregate_metrics"]["mean_retrieval_recall"] == 1.0
    assert retrieval_task["aggregate_metrics"]["full_retrieval_recall_rows"] == 3
    assert claim_task["aggregate_metrics"]["mean_retrieval_recall"] == 1.0
    assert claim_task["aggregate_metrics"]["full_retrieval_recall_rows"] == 3

    assert Enum.all?(retrieval_task["rows"], fn row ->
             row["metric_metadata"]["primary"]["exact_match"] == true and
               row["metric_metadata"]["retrieval"]["recall"] == 1.0
           end)

    assert Enum.all?(claim_task["rows"], fn row ->
             row["metric_metadata"]["primary"]["correct"] == true and
               row["metric_metadata"]["retrieval"]["recall"] == 1.0
           end)
  end

  test "fixture benchmark truth runner evaluates composition and orchestration scenarios" do
    Application.ensure_all_started(:imp)
    out_dir = tmp_dir("composition-results")

    [composition] =
      Imp.BenchmarkTruth.fetch(["composition_orchestration"],
        out_dir: out_dir,
        length: :full
      )

    result =
      Imp.BenchmarkTruth.run(
        tasks: [composition_orchestration: composition.data_path],
        out_dir: out_dir,
        max_examples: 3,
        max_concurrency: 2
      )

    [task] = result.report["tasks"]
    assert result.report["aggregate_score"] == 1.0
    assert task["task"] == "composition_orchestration"
    assert task["score"] == 1.0
    assert task["aggregate_metrics"]["scenarios"] == 6
    assert task["aggregate_metrics"]["passed"] == 6
    assert task["aggregate_metrics"]["failed_child_isolation"] == true
    assert task["aggregate_metrics"]["max_concurrency"] == 2

    scenarios = Map.new(task["scenarios"], &{&1["name"], &1})

    assert Map.keys(scenarios) |> Enum.sort() ==
             [
               "best_of_n",
               "ensemble",
               "knn",
               "multi_chain_comparison",
               "parallel",
               "refine"
             ]

    assert scenarios["best_of_n"]["base_score"] == 0.0
    assert scenarios["best_of_n"]["composed_score"] == 1.0
    assert scenarios["refine"]["history_length"] == 2
    assert scenarios["ensemble"]["failed_child_isolation"] == true
    assert scenarios["parallel"]["failed_child_isolation"] == true
    assert scenarios["parallel"]["max_concurrency"] == 2
    assert scenarios["knn"]["demo_count"] == 2
    assert File.exists?(result.out_path)
  end

  test "fixture benchmark truth runner evaluates IFBench constraints and hard math exact answers" do
    out_dir = tmp_dir("ifbench-hard-math-results")

    [ifbench, hard_math] =
      Imp.BenchmarkTruth.fetch(["ifbench_instruction_following", "hard_math"],
        out_dir: out_dir,
        length: :full
      )

    result =
      Imp.BenchmarkTruth.run(
        tasks: [
          ifbench_instruction_following: ifbench.data_path,
          hard_math: hard_math.data_path
        ],
        out_dir: out_dir,
        max_examples: 3,
        optimizer_comparisons: false
      )

    assert result.report["aggregate_score"] == 1.0

    by_task = Map.new(result.report["tasks"], &{&1["task"], &1})
    ifbench_task = by_task["ifbench_instruction_following"]
    hard_math_task = by_task["hard_math"]

    assert ifbench_task["score"] == 1.0
    assert ifbench_task["aggregate_metrics"]["mean_constraint_score"] == 1.0
    assert ifbench_task["aggregate_metrics"]["full_constraint_rows"] == 3

    assert Enum.all?(ifbench_task["rows"], fn row ->
             row["metric_metadata"]["task_metric"] == "ifbench_constraint_satisfaction" and
               row["metric_metadata"]["constraint_count"] >= 1 and
               row["metric_metadata"]["satisfied_constraints"] ==
                 row["metric_metadata"]["constraint_count"]
           end)

    assert hard_math_task["score"] == 1.0
    assert hard_math_task["aggregate_metrics"]["accuracy"] == 1.0
    assert hard_math_task["aggregate_metrics"]["exact_rows"] == 3

    assert Enum.all?(hard_math_task["rows"], fn row ->
             row["metric_metadata"]["task_metric"] == "hard_math_normalized_exact_match" and
               row["metric_metadata"]["numeric_equivalent"] == true
           end)
  end

  test "benchmark truth rows include compact diagnostics for failed predictions" do
    out_dir = tmp_dir("diagnostic-results")

    result =
      Imp.BenchmarkTruth.run(
        tasks: [hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "wrong answer"} end]
        },
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    refute row["passed"]
    assert row["diagnostic"]["gold_answer"]
    assert row["diagnostic"]["question"]
    assert byte_size(row["diagnostic"]["context_sha256"]) == 64
    assert is_integer(row["diagnostic"]["context_length"])
    assert row["diagnostic"]["trace"]["messages"] != []
    [system | _rest] = row["diagnostic"]["trace"]["messages"]
    assert system["content"] =~ "`answer` (str): short exact answer"
    refute system["content"] =~ "Must be a concise exact answer span"
    assert system["content"] =~ "For yes/no questions, answer exactly yes or no."
    assert system["content"] =~ "Return the canonical exact answer span from the context."
    assert system["content"] =~ "Do not abbreviate locations, titles, names, dates, or quantities"
    assert row["metric_metadata"]["task_metric"] == "hotpotqa_exact_match"
    assert row["metric_metadata"]["official_hotpotqa_em"] == false
    assert is_number(row["metric_metadata"]["official_hotpotqa_f1"])
  end

  test "HotPotQA benchmark treats verbose wrong answers as metric failures, not parse errors" do
    out_dir = tmp_dir("hotpotqa-verbose-answer")

    verbose_answer =
      "United States Ambassador to Ghana and to Czechoslovakia, and Chief of Protocol of the United States"

    result =
      Imp.BenchmarkTruth.run(
        tasks: [hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: verbose_answer} end]
        },
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    refute row["passed"]
    assert row["error"] == nil
    assert row["prediction"][:answer] == verbose_answer
    assert task["errors"] == []
    assert row["metric_metadata"]["task_metric"] == "hotpotqa_exact_match"
    assert row["metric_metadata"]["official_hotpotqa_em"] == false
  end

  test "benchmark truth diagnostics include traces for adapter parse failures" do
    out_dir = tmp_dir("parse-failure-diagnostics")

    result =
      Imp.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn _messages, _opts ->
              "[[ ## reasoning ## ]]\nI forgot the answer field.\n[[ ## completed ## ]]"
            end
          ]
        },
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    refute row["passed"]
    assert row["error"]["reason"] == ["error", ["missing_output_fields", ["answer"]]]
    assert row["diagnostic"]["trace"]["raw"] =~ "I forgot the answer field."
    assert row["diagnostic"]["trace"]["messages"] != []
  end

  test "benchmark truth reports provider errors with improper-list terms" do
    out_dir = tmp_dir("improper-list-error")
    improper_reason = [:provider_error | "messages"]

    result =
      Imp.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: fn _messages, _opts -> {:error, improper_reason} end,
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    refute row["passed"]
    assert row["error"] == inspect(improper_reason)
    assert [%{"reason" => reason}] = task["errors"]
    assert reason == inspect(improper_reason)
    assert File.exists?(result.out_path)
  end

  test "benchmark truth rows include Imp runtime instrumentation" do
    out_dir = tmp_dir("instrumented-results")

    lm = Imp.req_llm("openai:gpt-test", test_pid: self(), req_module: ReqLLMStub)

    result =
      Imp.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: lm,
        optimizer_comparisons: false
      )

    assert_received {:benchmark_req_llm_generate, _message_count}

    [task] = result.report["tasks"]
    [row] = task["rows"]

    assert row["passed"]
    assert row["instrumentation"]["lm_calls"] == 1
    assert is_number(row["instrumentation"]["lm_duration_ms"])
    assert row["instrumentation"]["json_fallbacks"] == 0
    assert row["instrumentation"]["parse_retries"] == 0
    assert row["instrumentation"]["message_count"] == 2
    assert row["instrumentation"]["message_chars"] > 0
    assert row["instrumentation"]["raw_chars"] > 0
  end

  test "GSM8K metric accepts numerically equivalent final answers" do
    out_dir = tmp_dir("numeric-gsm8k")
    path = Path.join(out_dir, "gsm8k-one.jsonl")

    File.write!(path, """
    {"question":"What is the total?","answer":"Work. #### 29","canonical_answer":"29","source_task":"gsm8k"}
    """)

    result =
      Imp.BenchmarkTruth.run(
        tasks: [gsm8k: path],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn _messages, _opts ->
              "[[ ## reasoning ## ]] subtotal plus fees [[ ## answer ## ]] 29.00 [[ ## completed ## ]]"
            end
          ]
        },
        optimizer_comparisons: false
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    assert row["passed"]
    assert row["prediction"][:answer] == "29.00"
  end

  test "benchmark truth runner supports offset chunks" do
    out_dir = tmp_dir("offset-results")

    result =
      Imp.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        offset: 1,
        max_examples: 1
      )

    [task] = result.report["tasks"]
    [row] = task["rows"]

    assert task["offset"] == 1
    assert task["examples"] == 1
    assert row["prediction"][:answer] == "3"
  end

  test "benchmark data integrity reports missing HotPotQA supporting pages" do
    out_dir = tmp_dir("integrity-results")
    path = Path.join(out_dir, "bad-hotpotqa.jsonl")

    File.write!(path, """
    {"id":"bad","question":"q","answer":"Newport","context":"East Lempster, New Hampshire: East Lempster is in Sullivan County.","supporting_facts":{"title":["East Lempster, New Hampshire","Sullivan County, New Hampshire"],"sent_id":[0,2]},"source_task":"hotpotqa"}
    """)

    result = Imp.BenchmarkTruth.integrity([hotpotqa: path], out_dir: out_dir)
    [task] = result.report["tasks"]

    refute result.report["passing"]
    refute task["passing"]

    assert %{
             "index" => 0,
             "severity" => "error",
             "code" => "supporting_fact_title_absent_from_context",
             "title" => "Sullivan County, New Hampshire"
           } in task["issues"]

    assert Enum.any?(task["issues"], &(&1["code"] == "answer_absent_from_context"))
    assert File.exists?(result.out_path)
  end

  test "benchmark data integrity accepts checked-in benchmark fixtures" do
    out_dir = tmp_dir("integrity-fixtures")

    result =
      Imp.BenchmarkTruth.integrity(
        [
          gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl"),
          hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")
        ],
        out_dir: out_dir
      )

    assert result.report["passing"]
    assert Enum.all?(result.report["tasks"], & &1["passing"])
  end

  test "DSPy runner path parser requires explicit sentinel" do
    assert {:ok, "benchmarks/results/report.json"} =
             Mix.Tasks.Imp.Benchmark.Parity.parse_dspy_report_path("""
             warning: wrote debug.json
             DSPY_REPORT_PATH=benchmarks/results/report.json
             aggregate score: 1.0
             """)

    assert :error =
             Mix.Tasks.Imp.Benchmark.Parity.parse_dspy_report_path("""
             warning: this line ends in debug.json
             aggregate score: 1.0
             """)
  end

  test "DSPy parity runner persists bounded redacted provider exceptions" do
    runner_path = Path.expand("../scripts/dspy_parity_runner.py", __DIR__)
    out_path = Path.join(tmp_dir("dspy-error-redaction"), "report.json")
    secret = "provider-secret-value-0123456789"
    shaped_secret = "sk-test-python-runner-secret-1234567890"

    python = """
    import importlib.util
    import json
    import pathlib
    import sys
    import types

    fake = types.ModuleType("dspy")
    fake.__version__ = "fake"
    fake.settings = types.SimpleNamespace(lm=None)
    fake.Signature = type("Signature", (), {})
    fake.Module = type("Module", (), {})
    fake.ChainOfThought = lambda signature: None
    fake.Predict = lambda signature: None
    fake.InputField = lambda *args, **kwargs: None
    fake.OutputField = lambda *args, **kwargs: None
    fake.LM = lambda *args, **kwargs: None
    fake.configure = lambda **kwargs: None
    sys.modules["dspy"] = fake

    spec = importlib.util.spec_from_file_location("dspy_parity_runner", #{Jason.encode!(runner_path)})
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    runner.DIAGNOSTIC_SECRETS = (#{Jason.encode!(secret)},)

    error = RuntimeError(
        "provider failed " + #{Jason.encode!(secret)} + " " +
        #{Jason.encode!(shaped_secret)} + " " + ("x" * 5000)
    )
    diagnostic = runner.exception_diagnostic(7, error)
    out_path = pathlib.Path(#{Jason.encode!(out_path)})
    runner.write_report_atomically(out_path, {"errors": [diagnostic]})

    persisted = out_path.read_text()
    assert #{Jason.encode!(secret)} not in persisted
    assert #{Jason.encode!(shaped_secret)} not in persisted
    assert "repr" not in diagnostic
    assert diagnostic["type"] == "RuntimeError"
    assert diagnostic["reason_truncated"] is True
    assert len(diagnostic["reason"]) == diagnostic["reason_limit_chars"]
    assert diagnostic["reason_chars"] > diagnostic["reason_limit_chars"]
    assert not out_path.with_suffix(out_path.suffix + ".partial").exists()
    print(json.dumps(diagnostic))
    """

    {output, status} = System.cmd("python3", ["-c", python], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "[REDACTED]"
    refute output =~ secret
    refute output =~ shaped_secret
  end

  test "DSPy parity runner attributes concurrent LM history by unambiguous row question" do
    runner_path = Path.expand("../scripts/dspy_parity_runner.py", __DIR__)

    python = """
    import importlib.util
    import sys
    import types

    fake = types.ModuleType("dspy")
    fake.__version__ = "fake"
    fake.settings = types.SimpleNamespace(lm=None)
    fake.Signature = type("Signature", (), {})
    fake.Module = type("Module", (), {})
    fake.ChainOfThought = lambda signature: None
    fake.Predict = lambda signature: None
    fake.InputField = lambda *args, **kwargs: None
    fake.OutputField = lambda *args, **kwargs: None
    fake.LM = lambda *args, **kwargs: None

    def configure(**kwargs):
        fake.settings.lm = kwargs.get("lm")

    fake.configure = configure
    sys.modules["dspy"] = fake

    spec = importlib.util.spec_from_file_location("dspy_parity_runner", #{Jason.encode!(runner_path)})
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)

    class FakeLM:
        def __init__(self, history):
            self.history = history

    runner.dspy.settings.lm = FakeLM([
        {
            "messages": [{"content": "Question: alpha?"}],
            "response": {"answer": "A"},
            "usage": {"prompt_tokens": 11, "completion_tokens": 3},
            "cost": 0.001,
        },
        {
            "messages": [{"content": "Question: beta?"}],
            "response": {"answer": "B"},
            "usage": {"input_tokens": 13, "output_tokens": 5},
            "cost": 0.002,
        },
    ])

    beta = runner.attributed_history_entry(0, {"question": "beta?"})
    assert beta["response"]["answer"] == "B"
    assert runner.attributed_history_entry(1, {"question": "beta?"})["response"]["answer"] == "B"
    assert runner.attributed_history_entry(1, {"question": "anything"}) is None
    assert runner.attributed_history_entry(0, {"question": "missing?"}) is None

    usage = runner.history_instrumentation(beta)
    assert usage["input_tokens"] == 13
    assert usage["output_tokens"] == 5
    assert usage["usd"] == 0.002

    runner.dspy.settings.lm = FakeLM([
        {"messages": [{"content": "Question: duplicate?"}]},
        {"messages": [{"content": "Question: duplicate?"}]},
    ])

    assert runner.attributed_history_entry(0, {"question": "duplicate?"}) is None
    print("ok")
    """

    {output, status} = System.cmd("python3", ["-c", python], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "ok"
  end

  test "DSPy parity runner estimates message shape when concurrent LM history is ambiguous" do
    runner_path = Path.expand("../scripts/dspy_parity_runner.py", __DIR__)

    python = """
    import importlib.util
    import sys
    import types

    fake = types.ModuleType("dspy")
    fake.__version__ = "fake"
    fake.settings = types.SimpleNamespace(lm=types.SimpleNamespace(history=[]))
    fake.Signature = type("Signature", (), {})
    fake.Module = type("Module", (), {})
    fake.ChainOfThought = lambda signature: None
    fake.Predict = lambda signature: None
    fake.InputField = lambda *args, **kwargs: None
    fake.OutputField = lambda *args, **kwargs: None
    fake.LM = lambda *args, **kwargs: None
    fake.configure = lambda **kwargs: None
    sys.modules["dspy"] = fake

    spec = importlib.util.spec_from_file_location("dspy_parity_runner", #{Jason.encode!(runner_path)})
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)

    row = {"question": "Where?", "context": "In the provided context."}
    instrumentation = runner.dspy_instrumentation("hotpotqa", row, {"answer": "There"}, 12.0, 0)

    assert instrumentation["history_found"] is False
    assert instrumentation["message_chars"] == len(row["question"]) + len(row["context"])
    assert instrumentation["message_chars_source"] == "row_estimate"
    assert instrumentation["raw_chars_source"] == "prediction_fallback"
    print("ok")
    """

    {output, status} = System.cmd("python3", ["-c", python], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "ok"
  end

  test "DSPy parity runner keeps provider-qualified model names intact" do
    runner_path = Path.expand("../scripts/dspy_parity_runner.py", __DIR__)

    python = """
    import importlib.util
    import sys
    import types

    fake = types.ModuleType("dspy")
    fake.__version__ = "fake"
    fake.settings = types.SimpleNamespace(lm=None)
    fake.Signature = type("Signature", (), {})
    fake.Module = type("Module", (), {})
    fake.ChainOfThought = lambda signature: None
    fake.Predict = lambda signature: None
    fake.InputField = lambda *args, **kwargs: None
    fake.OutputField = lambda *args, **kwargs: None
    fake.LM = lambda *args, **kwargs: None
    fake.configure = lambda **kwargs: None
    sys.modules["dspy"] = fake

    spec = importlib.util.spec_from_file_location("dspy_parity_runner", #{Jason.encode!(runner_path)})
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)

    assert runner.dspy_lm_name("gpt-5.4-mini") == "openai/gpt-5.4-mini"
    assert runner.dspy_lm_name("responses/gpt-5.4-mini") == "openai/responses/gpt-5.4-mini"
    assert runner.dspy_lm_name("anthropic/claude-haiku-4-5") == "anthropic/claude-haiku-4-5"
    assert runner.wire_api("anthropic/claude-haiku-4-5") == "litellm_anthropic_messages"
    assert runner.wire_api("gemini/gemini-3-flash-preview") == "litellm_google_generate_content"
    assert runner.effective_generation(
        "responses/gpt-4.1-mini-2025-04-14", 0.0, 700, None
    ) == (
        {"temperature": 0.0, "max_tokens": 700},
        ["DSPy/LiteLLM routed this comparison through OpenAI Responses for endpoint-equivalent parity"],
    )
    assert runner.effective_generation(
        "responses/gpt-5.4-mini", 0.0, 700, "low"
    )[0] == {"max_completion_tokens": 700, "reasoning_effort": "low"}

    matching = {"messages": [{"content": "Question A\\nContext A"}]}
    collision = {"messages": [{"content": "Question A\\nContext B"}]}
    fake.settings.lm = types.SimpleNamespace(history=[matching, collision])
    assert runner.attributed_history_entry(
        1, {"question": "Question A", "context": "Context A"}
    ) == matching
    print("ok")
    """

    {output, status} = System.cmd("python3", ["-c", python], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "ok"
  end

  test "parity task parses reasoning effort option" do
    assert {[reasoning_effort: "low"], [], []} =
             Mix.Tasks.Imp.Benchmark.Parity.parse_args(["--reasoning-effort", "low"])

    generation_opts =
      Mix.Tasks.Imp.Benchmark.Parity.generation_opts(
        reasoning_effort: "low",
        temperature: 0.0,
        max_tokens: 700
      )

    assert Keyword.fetch!(generation_opts, :temperature) == 0.0
    assert Keyword.fetch!(generation_opts, :max_tokens) == 700
    assert Keyword.fetch!(generation_opts, :reasoning_effort) == "low"
  end

  test "parity task only auto-selects unambiguous models returned by provider discovery" do
    assert {:ok, "gpt-future-mini"} =
             Mix.Tasks.Imp.Benchmark.Parity.select_default_openai_model([
               "text-embedding-3-large",
               "gpt-future-mini",
               "gpt-future-audio-preview"
             ])

    assert {:error, {:ambiguous_text_generation_models, ["gpt-alpha", "gpt-beta"]}} =
             Mix.Tasks.Imp.Benchmark.Parity.select_default_openai_model([
               "gpt-beta",
               "gpt-alpha"
             ])

    assert {:error, :no_models} =
             Mix.Tasks.Imp.Benchmark.Parity.select_default_openai_model([])

    assert {:error, {:no_text_generation_model, ["text-embedding-3-large", "tts-1"]}} =
             Mix.Tasks.Imp.Benchmark.Parity.select_default_openai_model([
               "text-embedding-3-large",
               "tts-1"
             ])
  end

  test "parity task can configure ReqLLM pool before app startup" do
    previous_protocols = Application.get_env(:req_llm, :stream_pool_protocols)
    previous_size = Application.get_env(:req_llm, :stream_pool_size)
    previous_count = Application.get_env(:req_llm, :stream_pool_count)

    try do
      assert {[req_llm_pool_protocols: "http2", req_llm_pool_count: 16], [], []} =
               Mix.Tasks.Imp.Benchmark.Parity.parse_args([
                 "--req-llm-pool-protocols",
                 "http2",
                 "--req-llm-pool-count",
                 "16"
               ])

      pool_opts =
        Mix.Tasks.Imp.Benchmark.Parity.configure_req_llm_pool!(
          req_llm_pool_protocols: "http2",
          req_llm_pool_count: 16
        )

      assert Keyword.fetch!(pool_opts, :stream_pool_protocols) == [:http2]
      assert Keyword.fetch!(pool_opts, :stream_pool_count) == 16

      assert Application.get_env(:req_llm, :stream_pool_protocols) == [:http2]
      assert Application.get_env(:req_llm, :stream_pool_count) == 16

      assert Mix.Tasks.Imp.Benchmark.Parity.req_llm_pool_config(max_concurrency: 8) == %{
               "count" => 1,
               "protocols" => [:http1],
               "size" => 8
             }

      assert Mix.Tasks.Imp.Benchmark.Parity.req_llm_pool_config(
               req_llm_pool_protocols: "http1",
               req_llm_pool_count: 16
             ) == %{"count" => 16, "protocols" => [:http1], "size" => 1}

      assert Mix.Tasks.Imp.Benchmark.Parity.req_llm_pool_config(
               req_llm_pool_protocols: "http2",
               max_concurrency: 8
             ) == %{"count" => 1, "protocols" => [:http2]}
    after
      restore_app_env(:req_llm, :stream_pool_protocols, previous_protocols)
      restore_app_env(:req_llm, :stream_pool_size, previous_size)
      restore_app_env(:req_llm, :stream_pool_count, previous_count)
    end
  end

  test "parity task supports explicit matched non-OpenAI provider specs" do
    assert {[model: "anthropic:claude-haiku-4-5", api_key_env: "ANTHROPIC_API_KEY"], [], []} =
             Mix.Tasks.Imp.Benchmark.Parity.parse_args([
               "--model",
               "anthropic:claude-haiku-4-5",
               "--api-key-env",
               "ANTHROPIC_API_KEY"
             ])

    assert Mix.Tasks.Imp.Benchmark.Parity.api_key_env(api_key_env: "ANTHROPIC_API_KEY") ==
             "ANTHROPIC_API_KEY"

    assert Mix.Tasks.Imp.Benchmark.Parity.imp_model_spec([], "gpt-5.4-mini") ==
             "openai:gpt-5.4-mini"

    assert Mix.Tasks.Imp.Benchmark.Parity.imp_model_spec(
             [],
             "anthropic:claude-haiku-4-5"
           ) == "anthropic:claude-haiku-4-5"

    assert Mix.Tasks.Imp.Benchmark.Parity.default_dspy_model(
             "anthropic:claude-haiku-4-5",
             "anthropic:claude-haiku-4-5"
           ) == "anthropic/claude-haiku-4-5"

    assert Mix.Tasks.Imp.Benchmark.Parity.default_dspy_model(
             "openai:gpt-5.4-mini",
             "gpt-5.4-mini"
           ) == "gpt-5.4-mini"

    assert Mix.Tasks.Imp.Benchmark.Parity.validate_dspy_model!("anthropic/claude-haiku-4-5") ==
             "anthropic/claude-haiku-4-5"

    assert_raise Mix.Error,
                 ~r/--dspy-model expects a Python DSPy\/LiteLLM model id such as anthropic\/claude-haiku-4-5/,
                 fn ->
                   Mix.Tasks.Imp.Benchmark.Parity.validate_dspy_model!(
                     "anthropic:claude-haiku-4-5"
                   )
                 end
  end

  test "parity aggregate deduplicates overlapping chunks and reports coverage gaps" do
    out_dir = tmp_dir("parity-aggregate")
    write_parity_report(out_dir, "older.json", "2026-07-06T00:00:00Z", 0, [true, false])
    write_parity_report(out_dir, "newer.json", "2026-07-06T00:01:00Z", 1, [true, true])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert campaign["provider"] == "req_llm"
    assert campaign["model"] == "gpt-test"
    assert campaign["coverage"]["covered"] == 3
    refute campaign["coverage"]["full"]
    refute campaign["parity"]["full_parity"]
    assert campaign["parity"]["latency_parity"]
    assert campaign["generation"]["consistent"]

    assert campaign["generation"]["value"] == %{
             "temperature" => 0.0,
             "max_tokens" => 700,
             "prompt_contract" => "legacy-unrecorded"
           }

    assert gsm8k["coverage"]["covered"] == 3
    assert gsm8k["imp_passes"] == 3
    assert gsm8k["dspy_passes"] == 3
    assert gsm8k["row_latency"]["imp"]["count"] == 3
    assert gsm8k["row_latency"]["dspy"]["count"] == 3
    assert gsm8k["row_latency"]["ratio_imp_over_dspy"]["mean"] == 2.0
    assert gsm8k["imp_instrumentation"]["coverage"]["instrumented_rows"] == 3
    assert gsm8k["imp_instrumentation"]["coverage"]["complete"]
    assert gsm8k["imp_instrumentation"]["lm_calls"] == 3
    assert gsm8k["imp_instrumentation"]["json_fallbacks"] == 0
    assert gsm8k["imp_instrumentation"]["parse_retries"] == 0
    assert gsm8k["imp_instrumentation"]["lm_duration"]["mean_ms"] == 18.0
    assert gsm8k["imp_instrumentation"]["local_overhead_ms"]["mean_ms"] == 2.0
    assert gsm8k["imp_instrumentation"]["lm_duration_share"]["mean"] == 0.9
    assert gsm8k["imp_instrumentation"]["message_chars"]["mean_chars"] == 101.0
    assert gsm8k["imp_instrumentation"]["message_chars"]["p90_chars"] == 102
    assert gsm8k["imp_instrumentation"]["raw_chars"]["mean_chars"] == 51.0
    assert gsm8k["dspy_instrumentation"]["coverage"]["instrumented_rows"] == 3
    assert gsm8k["dspy_instrumentation"]["coverage"]["complete"]
    assert gsm8k["dspy_instrumentation"]["lm_calls"] == 3
    assert gsm8k["dspy_instrumentation"]["input_chars"]["mean_chars"] == 81.0
    assert gsm8k["runtime_shape"]["message_chars_ratio_imp_over_dspy_mean"] == 0.5
    assert gsm8k["runtime_shape"]["raw_chars_ratio_imp_over_dspy_mean"] == 0.5

    assert gsm8k["runtime_shape"]["coverage"] == %{
             "total_rows" => 3,
             "message_chars_comparable_rows" => 3,
             "raw_chars_comparable_rows" => 3,
             "complete" => true
           }

    assert [%{"from" => 3, "to" => 1318} | _] = gsm8k["coverage"]["missing_ranges"]

    assert %{"task" => "gsm8k", "next_offset" => 3} =
             Enum.find(campaign["next_chunks"], &(&1["task"] == "gsm8k"))
  end

  test "parity aggregate reports effective generation wire API mismatch" do
    out_dir = tmp_dir("parity-aggregate-wire-api")

    write_parity_report(
      out_dir,
      "wire-mismatch.json",
      "2026-07-06T00:00:00Z",
      0,
      [true],
      generation: %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "imp" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "openai_responses"
        },
        "dspy" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "litellm_chat_completion"
        }
      }
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    effective = campaign["generation"]["effective"]

    assert effective["complete"]
    assert effective["matched"]
    assert effective["wire_api_complete"]
    refute effective["wire_api_matched"]
    assert effective["imp_wire_api_distinct"] == ["openai_responses"]
    assert effective["dspy_wire_api_distinct"] == ["litellm_chat_completion"]
    refute campaign["parity"]["full_parity"]
  end

  test "parity aggregate preserves complete provider-reported row usage" do
    out_dir = tmp_dir("parity-aggregate-usage")

    rows =
      Enum.map(0..1, fn index ->
        complete_row(index, true)
        |> Map.put("imp_instrumentation", %{
          "usage_events" => 1,
          "input_tokens" => 100 + index,
          "output_tokens" => 20 + index,
          "usd" => 0.01 + index * 0.001
        })
        |> Map.put("dspy_instrumentation", %{
          "lm_calls" => 1,
          "usage_found" => true,
          "input_tokens" => 90 + index,
          "output_tokens" => 18 + index,
          "usd" => 0.009 + index * 0.001
        })
      end)

    write_parity_rows(out_dir, "usage.json", rows)

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()

    assert campaign["usage"]["coverage"] == %{"complete" => true, "total_rows" => 2}
    assert campaign["usage"]["imp"]["input_tokens"] == 201
    assert campaign["usage"]["dspy"]["input_tokens"] == 181
    assert campaign["usage"]["total"]["requests"] == 4
    assert campaign["usage"]["total"]["output_tokens"] == 78
    assert_in_delta campaign["usage"]["total"]["usd"], 0.04, 1.0e-12
  end

  test "live matrix projects remaining cost from complete observed usage" do
    in_dir = tmp_dir("live-matrix-observed-usage-input")
    out_dir = tmp_dir("live-matrix-observed-usage-output")

    write_campaign_artifact(in_dir, "observed.json", %{
      "provider" => "req_llm",
      "model" => "gpt-mini-observed",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 2, "expected" => 10, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "usage" => %{
        "coverage" => %{"complete" => true, "total_rows" => 2},
        "imp" => %{"input_tokens" => 60, "output_tokens" => 10, "usd" => 0.03},
        "dspy" => %{"input_tokens" => 40, "output_tokens" => 10, "usd" => 0.02},
        "total" => %{"input_tokens" => 100, "output_tokens" => 20, "usd" => 0.05}
      },
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        out_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(out_dir, "live-matched-model-matrix-*.json"))
    [model] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert model["cost"]["status"] == "observed_provider_usage"
    assert model["cost"]["observed_total_tokens"] == 120
    assert model["cost"]["estimated_remaining_total_tokens"] == 480
    assert model["cost"]["estimated_full_total_tokens"] == 600
    assert_in_delta model["cost"]["estimated_remaining_usd"], 0.2, 1.0e-12
    assert_in_delta model["cost"]["estimated_full_usd"], 0.25, 1.0e-12
  end

  test "parity aggregate ignores superseded chunks for generation proof" do
    out_dir = tmp_dir("parity-aggregate-superseded-generation")

    write_parity_report(
      out_dir,
      "older-wrong-wire.json",
      "2026-07-06T00:00:00Z",
      0,
      [true],
      generation: %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "imp" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "anthropic_messages"
        },
        "dspy" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "litellm_chat_completion"
        }
      }
    )

    write_parity_report(
      out_dir,
      "newer-right-wire.json",
      "2026-07-06T00:01:00Z",
      0,
      [true],
      generation: %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "imp" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "anthropic_messages"
        },
        "dspy" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "litellm_anthropic_messages"
        }
      }
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    effective = campaign["generation"]["effective"]

    assert effective["wire_api_matched"]
    assert effective["dspy_wire_api_distinct"] == ["litellm_anthropic_messages"]

    assert Enum.map(campaign["source_reports"], & &1["path"]) == [
             Path.join(out_dir, "newer-right-wire.json")
           ]

    assert Enum.map(campaign["ignored_source_reports"], & &1["path"]) == [
             Path.join(out_dir, "older-wrong-wire.json")
           ]
  end

  test "parity aggregate records mixed max concurrency as non-release-safe evidence" do
    out_dir = tmp_dir("parity-aggregate-mixed-concurrency")

    write_parity_report(out_dir, "concurrency-4.json", "2026-07-06T00:00:00Z", 0, [true],
      max_concurrency: 4
    )

    write_parity_report(out_dir, "concurrency-8.json", "2026-07-06T00:01:00Z", 1, [true],
      max_concurrency: 8
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()

    assert campaign["execution"]["max_concurrency_values"] == [4, 8]
    assert campaign["execution"]["max_concurrency_consistent"] == false
    assert campaign["parity"]["max_concurrency_consistent"] == false
    refute campaign["parity"]["full_parity"]
  end

  test "parity aggregate can select one max concurrency slice for release evidence" do
    out_dir = tmp_dir("parity-aggregate-filter-concurrency")

    write_parity_report(out_dir, "concurrency-4.json", "2026-07-06T00:00:00Z", 0, [true],
      max_concurrency: 4
    )

    write_parity_report(out_dir, "concurrency-8.json", "2026-07-06T00:01:00Z", 1, [true],
      max_concurrency: 8
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test",
        "--max-concurrency",
        "4"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()

    assert campaign["coverage"]["covered"] == 1
    assert campaign["execution"]["max_concurrency_values"] == [4]
    assert campaign["execution"]["max_concurrency"] == 4
    assert campaign["execution"]["max_concurrency_consistent"]
    assert [%{"max_concurrency" => 4}] = campaign["source_reports"]
  end

  test "parity aggregate treats ReqLLM and LiteLLM chat completion labels as one endpoint family" do
    out_dir = tmp_dir("parity-aggregate-wire-api-chat-family")

    write_parity_report(
      out_dir,
      "chat-family.json",
      "2026-07-06T00:00:00Z",
      0,
      [true],
      generation: %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "imp" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "openai_chat_completions"
        },
        "dspy" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "litellm_chat_completion"
        }
      }
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))

    effective =
      campaign_path |> File.read!() |> Jason.decode!() |> get_in(["generation", "effective"])

    assert effective["wire_api_complete"]
    assert effective["wire_api_matched"]
    assert effective["imp_wire_api_distinct"] == ["openai_chat_completions"]
    assert effective["dspy_wire_api_distinct"] == ["litellm_chat_completion"]

    assert effective["imp_wire_endpoint_families"] == ["openai_chat_completions"]
    assert effective["dspy_wire_endpoint_families"] == ["openai_chat_completions"]
  end

  test "parity aggregate treats ReqLLM and LiteLLM Anthropic labels as one endpoint family" do
    out_dir = tmp_dir("parity-aggregate-wire-api-anthropic-family")

    write_parity_report(
      out_dir,
      "anthropic-family.json",
      "2026-07-06T00:00:00Z",
      0,
      [true],
      generation: %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "imp" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "anthropic_messages"
        },
        "dspy" => %{
          "effective" => %{"temperature" => 0.0, "max_tokens" => 700},
          "wire_api" => "litellm_anthropic_messages"
        }
      }
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))

    effective =
      campaign_path |> File.read!() |> Jason.decode!() |> get_in(["generation", "effective"])

    assert effective["wire_api_complete"]
    assert effective["wire_api_matched"]
    assert effective["imp_wire_endpoint_families"] == ["anthropic_messages"]
    assert effective["dspy_wire_endpoint_families"] == ["anthropic_messages"]
  end

  test "parity aggregate marks runtime shape incomplete when DSPy history is partial" do
    out_dir = tmp_dir("parity-aggregate-partial-runtime-shape")

    write_parity_rows(out_dir, "partial-runtime-shape.json", [
      complete_row(0, true)
      |> put_in(["imp_instrumentation"], %{"message_chars" => 100, "raw_chars" => 50})
      |> put_in(["dspy_instrumentation"], %{"message_chars" => 200, "raw_chars" => 100}),
      complete_row(1, true)
      |> put_in(["imp_instrumentation"], %{"message_chars" => 300, "raw_chars" => 150})
      |> put_in(["dspy_instrumentation"], %{"raw_chars" => 300})
    ])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["runtime_shape"]["message_chars_ratio_imp_over_dspy_mean"] == 0.5
    assert gsm8k["runtime_shape"]["raw_chars_ratio_imp_over_dspy_mean"] == 0.5

    assert gsm8k["runtime_shape"]["coverage"] == %{
             "total_rows" => 2,
             "message_chars_comparable_rows" => 1,
             "raw_chars_comparable_rows" => 2,
             "complete" => false
           }
  end

  test "parity aggregate records DSPy message shape provenance" do
    out_dir = tmp_dir("parity-aggregate-runtime-shape-provenance")

    write_parity_rows(out_dir, "runtime-shape-provenance.json", [
      complete_row(0, true)
      |> put_in(["imp_instrumentation"], %{"message_chars" => 100, "raw_chars" => 50})
      |> put_in(["dspy_instrumentation"], %{
        "message_chars" => 200,
        "message_chars_source" => "lm_history",
        "raw_chars" => 100,
        "raw_chars_source" => "lm_history",
        "history_found" => true
      }),
      complete_row(1, true)
      |> put_in(["imp_instrumentation"], %{"message_chars" => 300, "raw_chars" => 150})
      |> put_in(["dspy_instrumentation"], %{
        "message_chars" => 300,
        "message_chars_source" => "row_estimate",
        "raw_chars" => 75,
        "raw_chars_source" => "prediction_fallback",
        "history_found" => false
      })
    ])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["runtime_shape"]["coverage"]["complete"]

    assert gsm8k["dspy_instrumentation"]["message_chars_sources"] == %{
             "lm_history" => 1,
             "row_estimate" => 1
           }

    assert gsm8k["dspy_instrumentation"]["raw_chars_sources"] == %{
             "lm_history" => 1,
             "prediction_fallback" => 1
           }
  end

  test "parity aggregate refuses to count out-of-range rows as canonical coverage" do
    out_dir = tmp_dir("parity-aggregate-out-of-range")

    rows =
      (0..1317
       |> Enum.map(&complete_row(&1, true))) ++
        [complete_row(2000, true)]

    write_parity_rows(out_dir, "out-of-range.json", rows)

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["coverage"]["covered"] == 1318
    assert gsm8k["coverage"]["out_of_range_rows"] == 1
    assert [%{"from" => 1318, "to" => 1318}] = gsm8k["coverage"]["missing_ranges"]
    refute gsm8k["coverage"]["full"]
    refute campaign["coverage"]["full"]
    refute campaign["parity"]["full_parity"]
  end

  test "parity aggregate treats missing counterpart rows as incomplete evidence" do
    out_dir = tmp_dir("parity-aggregate-incomplete-row")

    write_parity_rows(out_dir, "missing-counterpart.json", [
      %{
        "index" => 0,
        "absolute_index" => 0,
        "imp_row_present" => true,
        "dspy_row_present" => false,
        "row_evidence_complete" => false,
        "imp_passed" => true,
        "dspy_passed" => nil,
        "pass_agreement" => nil,
        "answer_agreement" => nil,
        "imp_answer" => "0",
        "dspy_answer" => nil
      }
    ])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["coverage"]["covered"] == 0
    assert gsm8k["coverage"]["incomplete_rows"] == 1
    assert [%{"from" => 0, "to" => 1318}] = gsm8k["coverage"]["missing_ranges"]
    assert gsm8k["imp_passes"] == 0
    assert gsm8k["dspy_passes"] == 0
    refute campaign["coverage"]["full"]
    refute campaign["parity"]["full_parity"]
  end

  test "parity aggregate treats runner error rows as incomplete and preserves older complete evidence" do
    out_dir = tmp_dir("parity-aggregate-runner-errors")

    write_parity_rows(out_dir, "older-complete.json", [complete_row(0, true)])

    failed_row =
      complete_row(0, false)
      |> Map.merge(%{
        "imp_answer" => nil,
        "dspy_answer" => nil,
        "imp_instrumentation" => %{"lm_calls" => 1},
        "dspy_instrumentation" => %{"lm_calls" => 1}
      })

    failed_report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:01:00Z",
      "campaign_id" => nil,
      "imp" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => 0,
          "examples" => 1,
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "imp_errors" => [%{"index" => 0, "reason" => "insufficient_quota"}],
          "dspy_errors" => [%{"index" => 0, "reason" => "insufficient_quota"}],
          "row_agreement" => [failed_row]
        }
      ],
      "evidence" => %{"examples" => 1}
    }

    File.write!(
      Path.join(out_dir, "newer-runner-error.json"),
      Jason.encode!(failed_report, pretty: true) <> "\n"
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["coverage"]["covered"] == 1
    assert gsm8k["coverage"]["runner_error_rows"] == 0
    assert gsm8k["imp_passes"] == 1
    assert gsm8k["dspy_passes"] == 1
    assert gsm8k["disagreements"]["count"] == 0
  end

  test "parity aggregate treats unindexed runner error counts as incomplete evidence" do
    out_dir = tmp_dir("parity-aggregate-runner-error-counts")

    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => nil,
      "imp" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => 0,
          "examples" => 1,
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "imp_errors" => 1,
          "dspy_errors" => 1,
          "row_agreement" => [
            complete_row(0, false)
            |> Map.put("imp_answer", nil)
            |> Map.put("dspy_answer", nil)
          ]
        }
      ],
      "evidence" => %{"examples" => 1}
    }

    File.write!(Path.join(out_dir, "runner-error-counts.json"), Jason.encode!(report) <> "\n")

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["coverage"]["covered"] == 0
    assert gsm8k["coverage"]["incomplete_rows"] == 1
    assert gsm8k["coverage"]["runner_error_rows"] == 1
  end

  test "parity aggregate refuses to mix provider identities" do
    out_dir = tmp_dir("parity-aggregate-provider")

    write_parity_report(out_dir, "req.json", "2026-07-06T00:00:00Z", 0, [true],
      provider: "req_llm"
    )

    write_parity_report(out_dir, "direct.json", "2026-07-06T00:01:00Z", 1, [true],
      provider: "openai-compatible"
    )

    assert_raise Mix.Error, ~r/requires one Imp provider\/model identity/, fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--provider",
        "req_llm",
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()

    assert campaign["provider"] == "req_llm"
    assert campaign["coverage"]["covered"] == 1
    assert campaign["generation"]["consistent"]
    assert [%{"provider" => "req_llm"}] = campaign["source_reports"]
  end

  test "parity aggregate can isolate one campaign id" do
    out_dir = tmp_dir("parity-aggregate-campaign-id")

    write_parity_report(out_dir, "old.json", "2026-07-06T00:00:00Z", 0, [true],
      campaign_id: "old-run"
    )

    write_parity_report(out_dir, "fresh-a.json", "2026-07-06T00:01:00Z", 0, [true],
      campaign_id: "fresh-run"
    )

    write_parity_report(out_dir, "fresh-b.json", "2026-07-06T00:02:00Z", 1, [true],
      campaign_id: "fresh-run"
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test",
        "--campaign-id",
        "fresh-run"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()

    assert campaign["campaign_id"] == "fresh-run"
    assert campaign["coverage"]["covered"] == 2
    assert Enum.all?(campaign["source_reports"], &(&1["campaign_id"] == "fresh-run"))
  end

  test "parity aggregate preserves HotPotQA F1 supporting evidence" do
    out_dir = tmp_dir("parity-aggregate-hotpot-f1")

    write_hotpotqa_parity_report(out_dir, "hotpot.json", [
      {true, true, 1.0, 1.0},
      {false, true, 0.5, 1.0}
    ])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    hotpotqa = Enum.find(campaign["tasks"], &(&1["task"] == "hotpotqa"))

    assert hotpotqa["score_delta"] == -0.5

    assert %{
             "imp" => 0.75,
             "dspy" => 1.0,
             "delta" => -0.25,
             "coverage" => %{"imp_rows" => 2, "dspy_rows" => 2, "total_rows" => 2}
           } = hotpotqa["supporting_metrics"]["official_hotpotqa_f1"]
  end

  test "parity aggregate carries bounded disagreement examples for engineering triage" do
    out_dir = tmp_dir("parity-aggregate-disagreements")

    write_parity_rows(out_dir, "disagreements.json", [
      complete_row(0, true),
      %{
        "index" => 1,
        "absolute_index" => 1,
        "imp_row_present" => true,
        "dspy_row_present" => true,
        "row_evidence_complete" => true,
        "imp_passed" => true,
        "dspy_passed" => false,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "imp_answer" => "Robert Boyle",
        "dspy_answer" => "Boyle",
        "imp_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "imp_metric_metadata" => %{
          "official_hotpotqa_f1" => 1.0,
          "normalized_prediction" => "robert boyle"
        },
        "dspy_metric_metadata" => %{
          "official_hotpotqa_f1" => 0.5,
          "normalized_prediction" => "boyle"
        },
        "diagnostic" => %{
          "imp" => %{
            "question" => "Who discovered the law?",
            "gold_answer" => "Robert Boyle",
            "context_sha256" => String.duplicate("a", 64),
            "context_length" => 1234,
            "trace" => %{"raw" => String.duplicate("verbose", 200)}
          },
          "dspy_error" => nil
        }
      },
      %{
        "index" => 2,
        "absolute_index" => 2,
        "imp_row_present" => true,
        "dspy_row_present" => true,
        "row_evidence_complete" => true,
        "imp_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "imp_answer" => "yes, because both are magazines",
        "dspy_answer" => "yes",
        "imp_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0
      }
    ])

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "imp-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["disagreements"]["count"] == 2
    assert gsm8k["disagreements"]["pass_disagreements"] == 2
    assert gsm8k["disagreements"]["answer_disagreements"] == 2

    assert gsm8k["disagreements"]["directions"] == %{
             "imp_only_pass" => 1,
             "dspy_only_pass" => 1
           }

    [first, second] = gsm8k["disagreements"]["examples"]
    assert first["absolute_index"] == 1
    assert first["direction"] == "imp_only_pass"
    assert first["imp_answer"] == "Robert Boyle"
    assert first["dspy_answer"] == "Boyle"
    assert first["source_report"] =~ "disagreements.json"
    assert first["imp_metric_metadata"]["official_hotpotqa_f1"] == 1.0
    assert first["diagnostic"]["imp"]["question"] == "Who discovered the law?"
    assert first["diagnostic"]["imp"]["gold_answer"] == "Robert Boyle"
    assert first["diagnostic"]["imp"]["context_length"] == 1234
    refute Map.has_key?(first["diagnostic"]["imp"], "trace")

    assert second["absolute_index"] == 2
    assert second["direction"] == "dspy_only_pass"
  end

  test "HotPotQA analysis classifies disagreement directions and span errors" do
    out_dir = tmp_dir("hotpot-analysis")
    data_path = Path.join(out_dir, "hotpotqa.jsonl")

    File.write!(data_path, """
    {"question":"How much?","answer":"$10.5 million","context":"x","source_task":"hotpotqa"}
    {"question":"Are both magazines?","answer":"yes","context":"x","source_task":"hotpotqa"}
    {"question":"Which city?","answer":"Paris France","context":"x","source_task":"hotpotqa"}
    """)

    write_hotpotqa_analysis_report(out_dir, "imp-dspy-parity-directory.json")

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.HotpotqaAnalysis.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--campaign-id",
        "analysis-run",
        "--hotpotqa",
        data_path
      ])
    end)

    [analysis_path] = Path.wildcard(Path.join(out_dir, "hotpotqa-disagreement-analysis-*.json"))
    analysis = analysis_path |> File.read!() |> Jason.decode!()

    assert analysis["campaign_id"] == "analysis-run"
    assert analysis["coverage"] == %{"covered" => 3, "disagreements" => 3}

    assert analysis["summary"]["pass_disagreements"] == 3
    assert analysis["summary"]["imp_passes"] == 1
    assert analysis["summary"]["dspy_passes"] == 2
    assert analysis["directions"]["dspy_only_pass"] == 2

    assert analysis["categories"]["imp_overlong_span"] == 1
    assert analysis["categories"]["imp_yes_no_explanation"] == 1
    assert analysis["categories"]["dspy_short_span"] == 1
    assert analysis["answer_types"]["yes_no"] == 1
  end

  test "HotPotQA analysis accepts a results directory" do
    out_dir = tmp_dir("hotpot-analysis-directory")
    data_path = Path.join(out_dir, "hotpotqa.jsonl")

    File.write!(data_path, """
    {"question":"How much?","answer":"$10.5 million","context":"x","source_task":"hotpotqa"}
    {"question":"Are both magazines?","answer":"yes","context":"x","source_task":"hotpotqa"}
    {"question":"Which city?","answer":"Paris France","context":"x","source_task":"hotpotqa"}
    """)

    write_hotpotqa_analysis_report(out_dir, "imp-dspy-parity-directory.json")

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.HotpotqaAnalysis.run([
        "--in",
        out_dir,
        "--out",
        out_dir,
        "--campaign-id",
        "analysis-run",
        "--hotpotqa",
        data_path
      ])
    end)

    [analysis_path] = Path.wildcard(Path.join(out_dir, "hotpotqa-disagreement-analysis-*.json"))
    analysis = analysis_path |> File.read!() |> Jason.decode!()

    assert analysis["coverage"] == %{"covered" => 3, "disagreements" => 3}
    assert analysis["summary"]["pass_disagreements"] == 3
  end

  test "HotPotQA analysis excludes answerless runner error rows" do
    out_dir = tmp_dir("hotpot-analysis-runner-errors")
    data_path = Path.join(out_dir, "hotpotqa.jsonl")

    File.write!(data_path, """
    {"question":"How much?","answer":"$10.5 million","context":"x","source_task":"hotpotqa"}
    {"question":"Are both magazines?","answer":"yes","context":"x","source_task":"hotpotqa"}
    {"question":"Which city?","answer":"Paris France","context":"x","source_task":"hotpotqa"}
    {"question":"Who?","answer":"Todd Fisher","context":"x","source_task":"hotpotqa"}
    """)

    write_hotpotqa_analysis_report(out_dir, "imp-dspy-parity-directory.json",
      extra_task_fields: %{"imp_errors" => 1, "dspy_errors" => 1},
      extra_rows: [
        %{
          "index" => 3,
          "absolute_index" => 3,
          "imp_passed" => false,
          "dspy_passed" => false,
          "pass_agreement" => true,
          "answer_agreement" => true,
          "imp_answer" => nil,
          "dspy_answer" => nil
        }
      ]
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.HotpotqaAnalysis.run([
        "--in",
        out_dir,
        "--out",
        out_dir,
        "--campaign-id",
        "analysis-run",
        "--hotpotqa",
        data_path
      ])
    end)

    [analysis_path] = Path.wildcard(Path.join(out_dir, "hotpotqa-disagreement-analysis-*.json"))
    analysis = analysis_path |> File.read!() |> Jason.decode!()

    assert analysis["coverage"] == %{"covered" => 3, "disagreements" => 3}
    assert analysis["summary"]["rows"] == 3
  end

  test "campaign planner advances only runnable datasets at the next missing offset" do
    aggregate = %{
      "next_chunks" => [
        %{"task" => "gsm8k", "next_offset" => 12, "remaining" => 1307},
        %{"task" => "hotpotqa", "next_offset" => 0, "remaining" => 7405},
        %{"task" => "unknown", "next_offset" => 0, "remaining" => 1}
      ]
    }

    assert [
             %{
               task: :hotpotqa,
               path: "hotpotqa.jsonl",
               offset: 0,
               remaining: 7405
             }
           ] =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.next_chunk_plan(aggregate, %{
               gsm8k: "gsm8k.jsonl",
               hotpotqa: "hotpotqa.jsonl"
             })

    assert [
             %{
               task: :gsm8k,
               path: "gsm8k.jsonl",
               offset: 12,
               remaining: 1307
             }
           ] =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.next_chunk_plan(aggregate, %{
               gsm8k: "gsm8k.jsonl"
             })
  end

  test "campaign chunk args preserve endpoint-equivalent DSPy route" do
    args =
      Mix.Tasks.Imp.Benchmark.Parity.Campaign.chunk_args(
        [
          dspy_model: "responses/gpt-5.4-mini",
          api_key_env: "OPENAI_API_KEY",
          chunk_size: 50,
          max_concurrency: 8,
          temperature: 0.0,
          max_tokens: 700,
          reasoning_effort: "low",
          env_file: ".env",
          req_llm_pool_protocols: "http2",
          req_llm_pool_count: 16,
          dspy_timeout_ms: 120_000
        ],
        "gpt-5.4-mini",
        "responses-route-full",
        [
          %{
            task: :gsm8k,
            path: "benchmarks/data/gsm8k-test-0-1319.jsonl",
            offset: 100,
            remaining: 1219
          }
        ],
        "benchmarks/results"
      )

    dspy_model_index = Enum.find_index(args, &(&1 == "--dspy-model"))

    assert Enum.at(args, dspy_model_index + 1) == "responses/gpt-5.4-mini"
    reasoning_effort_index = Enum.find_index(args, &(&1 == "--reasoning-effort"))
    env_file_index = Enum.find_index(args, &(&1 == "--env-file"))
    timeout_index = Enum.find_index(args, &(&1 == "--dspy-timeout-ms"))

    assert Enum.at(args, reasoning_effort_index + 1) == "low"
    assert Enum.at(args, env_file_index + 1) == ".env"
    assert Enum.at(args, timeout_index + 1) == "120000"
    assert "--model" in args
    assert "--runner-order" in args
    assert "--gsm8k" in args
    assert "--api-key-env" in args
    assert "--env-file" in args
    assert "--req-llm-pool-protocols" in args
    assert "--req-llm-pool-count" in args
  end

  test "campaign halt decision stops after any runner-error chunk" do
    assert Mix.Tasks.Imp.Benchmark.Parity.Campaign.halt_after_chunk?(100, 150, true)
    refute Mix.Tasks.Imp.Benchmark.Parity.Campaign.halt_after_chunk?(100, 100, false)
    assert Mix.Tasks.Imp.Benchmark.Parity.Campaign.halt_after_chunk?(100, 100, true)
    assert Mix.Tasks.Imp.Benchmark.Parity.Campaign.halt_after_chunk?(100, 90, true)
  end

  test "campaign target coverage shrinks chunk size to the next useful live slice" do
    aggregate = %{"coverage" => %{"covered" => 90}}

    two_task_plan = [
      %{task: :gsm8k, path: "gsm8k.jsonl", offset: 45, remaining: 1274},
      %{task: :hotpotqa, path: "hotpotqa.jsonl", offset: 45, remaining: 7360}
    ]

    assert 5 =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.planned_chunk_size(
               aggregate,
               two_task_plan,
               chunk_size: 50,
               target_coverage: 100
             )

    assert 50 =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.planned_chunk_size(
               aggregate,
               two_task_plan,
               chunk_size: 50,
               target_coverage: 1000
             )

    assert 1 =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.planned_chunk_size(
               %{"coverage" => %{"covered" => 100}},
               two_task_plan,
               chunk_size: 50,
               target_coverage: 100
             )

    assert 2 =
             Mix.Tasks.Imp.Benchmark.Parity.Campaign.planned_chunk_size(
               aggregate,
               [%{task: :gsm8k, path: "gsm8k.jsonl", offset: 1317, remaining: 2}],
               chunk_size: 50,
               target_coverage: 1000
             )
  end

  test "live matrix summarizes required model lanes and malformed artifacts" do
    out_dir = tmp_dir("live-matrix")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "mini.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 20, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "imp_errors" => [],
          "dspy_errors" => [],
          "imp_instrumentation" => %{
            "coverage" => %{
              "instrumented_rows" => 20,
              "total_rows" => 20,
              "complete" => true
            },
            "lm_calls" => 20,
            "json_fallbacks" => 1,
            "parse_retries" => 0,
            "lm_duration_share" => %{"total" => 0.97},
            "local_overhead_ms" => %{"mean_ms" => 3.5}
          },
          "runtime_shape" => %{
            "coverage" => %{
              "total_rows" => 20,
              "message_chars_comparable_rows" => 20,
              "raw_chars_comparable_rows" => 20,
              "complete" => true
            },
            "message_chars_ratio_imp_over_dspy_mean" => 1.1,
            "raw_chars_ratio_imp_over_dspy_mean" => 0.25
          },
          "disagreements" => %{
            "count" => 2,
            "pass_disagreements" => 1,
            "answer_disagreements" => 2,
            "directions" => %{"imp_only_pass" => 1, "answer_or_evidence_mismatch" => 1},
            "examples" => [
              %{
                "absolute_index" => 1,
                "direction" => "imp_only_pass",
                "imp_answer" => "yes",
                "dspy_answer" => "American"
              }
            ]
          }
        }
      ]
    })

    write_campaign_artifact(in_dir, "mini-newer-tinier.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:01:00Z",
      "coverage" => %{"covered" => 2, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "mini-inflated-incomplete.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:02:00Z",
      "coverage" => %{"covered" => 30, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.0, "dspy_score" => 0.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "imp_instrumentation" => %{
            "coverage" => %{
              "instrumented_rows" => 20,
              "total_rows" => 30,
              "complete" => false
            }
          },
          "runtime_shape" => %{
            "coverage" => %{
              "total_rows" => 30,
              "message_chars_comparable_rows" => 20,
              "raw_chars_comparable_rows" => 20,
              "complete" => false
            }
          }
        }
      ]
    })

    write_campaign_artifact(in_dir, "historical.json", %{
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo-legacy",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.9, "dspy_score" => 0.9, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier-without-effective-generation.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.9, "dspy_score" => 0.9, "score_delta" => 0.0},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "malformed.json", %{
      "provider" => "req_llm",
      "model" => ["bad"],
      "coverage" => %{"covered" => 1, "expected" => 1, "full" => true},
      "parity" => %{"full_parity" => true}
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    required = matrix["summary"]["required_lanes"]

    assert matrix["summary"]["models"] == 3
    assert matrix["summary"]["skipped_malformed_artifacts"] == 1
    refute matrix["summary"]["matrix_complete"]
    assert required["current_low_cost"]["present"]
    assert required["frontier_sanity"]["present"]
    assert required["historical_research"]["full_evidence"]
    assert required["historical_research"]["satisfied"]
    refute required["frontier_sanity"]["full_evidence"]
    refute required["frontier_sanity"]["satisfied"]
    assert required["current_low_cost"]["best_status"] == "smoke"
    assert required["current_low_cost"]["models"] == ["gpt-5.4-mini"]
    assert required["current_low_cost"]["coverage"]["remaining_rows"] == 8704
    assert required["current_low_cost"]["cost"]["estimated_remaining_total_tokens"] == 28_340_224
    assert required["frontier_sanity"]["models"] == ["gpt-5.5"]
    assert required["historical_research"]["models"] == ["gpt-3.5-turbo-legacy"]

    mini = Enum.find(matrix["models"], &(&1["model"] == "gpt-5.4-mini"))
    assert mini["coverage"]["covered"] == 20

    assert mini["coverage_progress"] == %{
             "covered_rows" => 20,
             "expected_rows" => 8724,
             "remaining_rows" => 8704,
             "coverage_fraction" => 20 / 8724,
             "coverage_percent" => 0.2293,
             "full" => false
           }

    assert mini["cost"]["estimated_remaining_total_tokens"] == 28_340_224
    assert mini["cost"]["estimated_full_total_tokens"] == 28_405_344
    assert mini["disagreements"]["count"] == 2
    assert mini["disagreements"]["pass_disagreements"] == 1
    assert mini["disagreements"]["directions"]["imp_only_pass"] == 1
    assert [%{"task" => "gsm8k", "absolute_index" => 1}] = mini["disagreements"]["examples"]
    assert matrix["summary"]["disagreements"]["count"] == 2
    assert matrix["summary"]["disagreements"]["by_model"]["gpt-5.4-mini"]["count"] == 2
    assert mini["lane_tags"] == ["current_low_cost"]
    assert mini["proof"]["prompt_contract_current"]
    assert mini["imp_instrumentation"]["coverage"]["complete"]
    assert mini["imp_instrumentation"]["coverage"]["instrumented_rows"] == 20
    assert mini["imp_instrumentation"]["lm_calls"] == 20
    assert mini["imp_instrumentation"]["json_fallbacks"] == 1
    assert mini["imp_instrumentation"]["dominant_latency_source"] == "provider_model"
    assert mini["imp_instrumentation"]["max_local_overhead_mean_ms"] == 3.5
    assert mini["runtime_shape"]["complete"]
    assert mini["runtime_shape"]["coverage"]["complete"]
    assert mini["runtime_shape"]["coverage"]["message_chars_comparable_rows"] == 20
    assert mini["runtime_shape"]["tasks_with_runtime_shape"] == 1
    assert mini["runtime_shape"]["message_chars_ratio_imp_over_dspy_mean"] == 1.1
    assert mini["runtime_shape"]["raw_chars_ratio_imp_over_dspy_mean"] == 0.25
    assert matrix["summary"]["imp_instrumentation"]["models_with_complete_instrumentation"] == 1
    assert matrix["summary"]["imp_instrumentation"]["total_models"] == 3
    refute matrix["summary"]["imp_instrumentation"]["complete"]
    assert matrix["summary"]["runtime_shape"]["models_with_runtime_shape"] == 1
    assert matrix["summary"]["runtime_shape"]["models_with_complete_runtime_shape"] == 1
    assert matrix["summary"]["runtime_shape"]["total_models"] == 3
    assert matrix["summary"]["runtime_shape"]["mean_message_chars_ratio_imp_over_dspy"] == 1.1
    assert matrix["summary"]["runtime_shape"]["mean_raw_chars_ratio_imp_over_dspy"] == 0.25
    refute matrix["summary"]["runtime_shape"]["complete"]
    assert matrix["summary"]["runtime_shape"]["by_model"]["gpt-5.4-mini"]["complete"]

    assert matrix["summary"]["runtime_shape"]["by_model"]["gpt-5.4-mini"]["coverage"][
             "message_chars_comparable_rows"
           ] == 20

    assert matrix["summary"]["runtime_shape"]["by_model"]["gpt-5.5"] == %{
             "complete" => false,
             "coverage" => %{
               "complete" => false,
               "message_chars_comparable_rows" => 0,
               "raw_chars_comparable_rows" => 0,
               "total_rows" => 0
             },
             "by_task" => %{}
           }

    assert matrix["summary"]["prompt_contract"]["models_with_current_prompt_contract"] == 2
    assert matrix["summary"]["prompt_contract"]["total_models"] == 3
    refute matrix["summary"]["prompt_contract"]["complete"]
    assert matrix["summary"]["prompt_contract"]["by_model"]["gpt-5.4-mini"]["current"]

    frontier = Enum.find(matrix["models"], &(&1["model"] == "gpt-5.5"))
    assert frontier["lane_tags"] == ["frontier_sanity"]
    assert frontier["status"] == "full"
    refute frontier["full_evidence"]
    refute frontier["proof"]["effective_generation_complete"]

    historical = Enum.find(matrix["models"], &(&1["model"] == "gpt-3.5-turbo-legacy"))
    assert historical["lane_tags"] == ["historical_research"]

    assert Enum.all?(
             matrix["models"],
             &(&1["cost"]["status"] in ["token_estimate", "estimated_usd"])
           )

    assert Enum.any?(matrix["models"], &(&1["cost"]["estimated_total_tokens"] > 0))
  end

  test "live matrix applies lane-specific release policies" do
    out_dir = tmp_dir("live-matrix-lane-policy")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "current-sample.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier-sample.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => Map.put(sample_parity(), "max_task_score_gap", 0.010000000000000009),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "historical-sample.json", %{
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo-legacy",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    required = matrix["summary"]["required_lanes"]

    refute matrix["summary"]["matrix_complete"]
    refute required["current_low_cost"]["satisfied"]
    assert required["current_low_cost"]["policy"]["required_scale"] == "full"
    assert required["frontier_sanity"]["satisfied"]
    assert required["frontier_sanity"]["policy"]["required_scale"] == "research_sample"
    assert required["frontier_sanity"]["policy"]["required_outcome"] == "measurement"
    assert required["frontier_sanity"]["parity_outcome"] == "parity_established"
    assert required["historical_research"]["satisfied"]
    assert required["historical_research"]["policy"]["required_scale"] == "research_sample"
    assert required["historical_research"]["policy"]["required_outcome"] == "parity"
  end

  test "frontier measurement can complete without establishing parity" do
    out_dir = tmp_dir("live-matrix-frontier-measured-red")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "frontier-threshold-miss.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => Map.put(sample_parity(), "max_task_score_gap", 0.02),
      "aggregate" => %{"imp_score" => 0.87, "dspy_score" => 0.86, "score_delta" => 0.01},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))

    frontier =
      matrix_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["summary", "required_lanes", "frontier_sanity"])

    assert frontier["satisfied"]
    assert frontier["satisfaction"] == "evidence"
    assert frontier["parity_outcome"] == "parity_not_established"
    refute frontier["full_evidence"]
    assert frontier["best_parity"]["max_task_score_gap"] == 0.02
  end

  test "frontier measurement rejects nominal coverage with runtime errors" do
    out_dir = tmp_dir("live-matrix-frontier-error")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "frontier-error.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => [%{"task" => "hotpotqa", "imp_errors" => ["timeout"], "dspy_errors" => []}]
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))

    frontier =
      matrix_path
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["summary", "required_lanes", "frontier_sanity"])

    refute frontier["satisfied"]
    assert frontier["parity_outcome"] == "not_measured"
  end

  test "live matrix consumes model availability evidence for historical lane" do
    out_dir = tmp_dir("live-matrix-availability")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    availability_path = Path.join(out_dir, "model_availability.json")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "current-full.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-haiku-4-5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.9, "dspy_score" => 0.9, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier-sample.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_json!(availability_path, %{
      "schema_version" => 1,
      "unavailable_lanes" => %{
        "historical_research" => %{
          "note" => "Historical GPT-3.5 snapshots are unavailable."
        }
      }
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000",
        "--availability-file",
        availability_path
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    required = matrix["summary"]["required_lanes"]

    assert matrix["summary"]["matrix_complete"]
    assert required["historical_research"]["satisfied"]
    assert required["historical_research"]["satisfaction"] == "explicit_unavailable"

    assert required["historical_research"]["availability"] == %{
             "status" => "explicit_unavailable",
             "note" => "Historical GPT-3.5 snapshots are unavailable."
           }
  end

  test "live matrix refuses research-sample release proof without consistent concurrency" do
    out_dir = tmp_dir("live-matrix-concurrency-proof")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "frontier-mixed-concurrency.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "execution" => %{
        "max_concurrency_values" => [2, 8],
        "max_concurrency" => nil,
        "max_concurrency_consistent" => false
      },
      "tasks" => instrumented_task_pair(100)
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    [model] = matrix["models"]

    refute matrix["summary"]["required_lanes"]["frontier_sanity"]["satisfied"]
    refute matrix["summary"]["execution"]["complete"]
    refute model["proof"]["max_concurrency_consistent"]
    assert model["proof"]["max_concurrency_values"] == [2, 8]
  end

  test "live matrix can infer stale aggregate concurrency proof from source reports" do
    out_dir = tmp_dir("live-matrix-source-report-concurrency")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_legacy_campaign_artifact(in_dir, "frontier-source-report-concurrency.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "source_reports" => [
        %{"path" => "chunk-a.json", "max_concurrency" => 4},
        %{"path" => "chunk-b.json", "max_concurrency" => 4}
      ],
      "tasks" => instrumented_task_pair(100)
    })

    write_legacy_campaign_artifact(in_dir, "haiku-mixed-source-report-concurrency.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-haiku-4-5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "source_reports" => [
        %{"path" => "chunk-c.json", "max_concurrency" => 6},
        %{"path" => "chunk-d.json", "max_concurrency" => 8}
      ],
      "tasks" => instrumented_task_pair(100)
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--max-age-hours",
        "100000"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    frontier = Enum.find(matrix["models"], &(&1["model"] == "anthropic:claude-sonnet-4-6"))
    haiku = Enum.find(matrix["models"], &(&1["model"] == "anthropic:claude-haiku-4-5"))

    assert matrix["summary"]["required_lanes"]["frontier_sanity"]["satisfied"]
    assert frontier["proof"]["max_concurrency_consistent"]
    assert frontier["proof"]["max_concurrency"] == 4
    assert frontier["proof"]["max_concurrency_values"] == [4]

    refute haiku["proof"]["max_concurrency_consistent"]
    assert haiku["proof"]["max_concurrency_values"] == [6, 8]
  end

  test "live matrix keeps zero-coverage attempts out of selected model evidence" do
    out_dir = tmp_dir("live-matrix-zero-coverage")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "historical-zero.json", %{
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo",
      "campaign_id" => "historical-unavailable-smoke",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 0, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.0, "dspy_score" => 0.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "source_reports" => [%{"path" => "failed-chunk.json"}],
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()

    assert matrix["models"] == []
    assert matrix["summary"]["models"] == 0
    assert matrix["summary"]["skipped_zero_coverage_artifacts"] == 1
    assert matrix["summary"]["failed_attempts"]["count"] == 1
    refute matrix["summary"]["required_lanes"]["historical_research"]["present"]

    [attempt] = matrix["summary"]["failed_attempts"]["by_lane"]["historical_research"]
    assert attempt["model"] == "gpt-3.5-turbo"
    assert attempt["coverage"]["covered_rows"] == 0
  end

  test "live matrix accepts explicit historical lane unavailability without inventing evidence" do
    out_dir = tmp_dir("live-matrix-historical-unavailable")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "historical-zero.json", %{
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo",
      "campaign_id" => "historical-unavailable-smoke",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 0, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.0, "dspy_score" => 0.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "source_reports" => [%{"path" => "failed-chunk.json"}],
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--historical-unavailable-note",
        "OpenAI historical quota exhausted; Gemini key invalid; Claude 3 historical endpoints unavailable on this account."
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    historical = matrix["summary"]["required_lanes"]["historical_research"]

    assert matrix["models"] == []
    assert historical["satisfied"]
    assert historical["satisfaction"] == "explicit_unavailable"
    refute historical["full_evidence"]
    refute historical["present"]
    assert historical["availability"]["status"] == "explicit_unavailable"
    assert historical["best_model"] == nil

    assert matrix["summary"]["unavailable_lanes"]["historical_research"] =~
             "Claude 3 historical endpoints unavailable"
  end

  test "live matrix tags modern non-OpenAI model lanes" do
    out_dir = tmp_dir("live-matrix-non-openai-lanes")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "haiku.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-haiku-4-5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 1, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "runtime_shape" => %{
            "coverage" => %{
              "total_rows" => 1,
              "message_chars_comparable_rows" => 1,
              "raw_chars_comparable_rows" => 1,
              "complete" => true
            },
            "message_chars_ratio_imp_over_dspy_mean" => 1.0,
            "raw_chars_ratio_imp_over_dspy_mean" => 0.5
          }
        },
        %{
          "task" => "hotpotqa",
          "runtime_shape" => %{
            "coverage" => %{
              "total_rows" => 0,
              "message_chars_comparable_rows" => 0,
              "raw_chars_comparable_rows" => 0,
              "complete" => false
            }
          }
        }
      ]
    })

    write_campaign_artifact(in_dir, "mini.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 20, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "sonnet.json", %{
      "provider" => "req_llm",
      "model" => "anthropic:claude-sonnet-4-6",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 1, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "historical-gemini.json", %{
      "provider" => "req_llm",
      "model" => "gemini/gemini-1.5-pro",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 1, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    required = matrix["summary"]["required_lanes"]

    assert required["current_low_cost"]["present"]

    assert required["current_low_cost"]["models"] == [
             "anthropic:claude-haiku-4-5",
             "gpt-5.4-mini"
           ]

    assert required["current_low_cost"]["best_model"] == "gpt-5.4-mini"
    assert required["current_low_cost"]["coverage"]["covered_rows"] == 20
    assert required["current_low_cost"]["coverage"]["expected_rows"] == 8724
    assert required["current_low_cost"]["coverage"]["candidate_count"] == 2
    assert required["current_low_cost"]["coverage"]["cumulative"]["covered_rows"] == 21
    assert required["current_low_cost"]["coverage"]["cumulative"]["expected_rows"] == 17_448

    assert required["frontier_sanity"]["present"]
    assert required["frontier_sanity"]["models"] == ["anthropic:claude-sonnet-4-6"]
    assert required["historical_research"]["present"]
    assert required["historical_research"]["models"] == ["gemini/gemini-1.5-pro"]

    assert Enum.find(matrix["models"], &(&1["model"] == "anthropic:claude-haiku-4-5"))[
             "lane_tags"
           ] == ["current_low_cost"]

    assert Enum.find(matrix["models"], &(&1["model"] == "anthropic:claude-sonnet-4-6"))[
             "lane_tags"
           ] == ["frontier_sanity"]

    haiku = Enum.find(matrix["models"], &(&1["model"] == "anthropic:claude-haiku-4-5"))
    assert haiku["runtime_shape"]["complete"]
    assert haiku["runtime_shape"]["tasks_with_runtime_shape"] == 1
    assert Map.has_key?(haiku["runtime_shape"]["by_task"], "gsm8k")
    refute Map.has_key?(haiku["runtime_shape"]["by_task"], "hotpotqa")

    assert Enum.find(matrix["models"], &(&1["model"] == "gemini/gemini-1.5-pro"))[
             "lane_tags"
           ] == ["historical_research"]
  end

  test "live matrix prefers complete runtime-shape diagnostics over wider incomplete coverage" do
    out_dir = tmp_dir("live-matrix-coverage-rank")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "wide-partial-shape.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 300, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.84, "dspy_score" => 0.846, "score_delta" => -0.006},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "hotpotqa",
          "imp_errors" => [],
          "dspy_errors" => [],
          "imp_instrumentation" => %{
            "coverage" => %{
              "instrumented_rows" => 300,
              "total_rows" => 300,
              "complete" => true
            }
          },
          "runtime_shape" => %{
            "coverage" => %{
              "total_rows" => 300,
              "message_chars_comparable_rows" => 283,
              "raw_chars_comparable_rows" => 300,
              "complete" => false
            },
            "message_chars_ratio_imp_over_dspy_mean" => 1.05,
            "raw_chars_ratio_imp_over_dspy_mean" => 0.27
          }
        }
      ]
    })

    write_campaign_artifact(in_dir, "narrow-complete-shape.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:01:00Z",
      "coverage" => %{"covered" => 12, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.91, "dspy_score" => 0.91, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => instrumented_task_pair(6)
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [mini] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert mini["coverage"]["covered"] == 12
    assert mini["artifact"]["path"] =~ "narrow-complete-shape.json"
    assert mini["runtime_shape"]["complete"]
  end

  test "live matrix prefers current evidence policy over stale higher coverage" do
    out_dir = tmp_dir("live-matrix-evidence-policy-rank")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    base = %{
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => instrumented_task_pair(6)
    }

    write_campaign_artifact(
      in_dir,
      "old-policy-higher-coverage.json",
      Map.merge(base, %{
        "generated_at" => "2026-07-07T00:00:00Z",
        "coverage" => %{"covered" => 300, "expected" => 8724, "full" => false},
        "evidence_policy" => %{"version" => 1}
      })
    )

    write_campaign_artifact(
      in_dir,
      "current-policy-lower-coverage.json",
      Map.merge(base, %{
        "generated_at" => "2026-07-07T00:01:00Z",
        "coverage" => %{"covered" => 250, "expected" => 8724, "full" => false},
        "evidence_policy" => current_evidence_policy()
      })
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [mini] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert mini["coverage"]["covered"] == 250
    assert mini["artifact"]["path"] =~ "current-policy-lower-coverage.json"
    assert mini["proof"]["evidence_policy_current"]
  end

  test "live matrix accepts shell-expanded input files after --in" do
    out_dir = tmp_dir("live-matrix-expanded-inputs")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "current.json", %{
      "campaign_id" => "current-run",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier.json", %{
      "campaign_id" => "frontier-run",
      "provider" => "req_llm",
      "model" => "gpt-5.5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "historical.json", %{
      "campaign_id" => "historical-run",
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo-legacy",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    [first | rest] = in_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run(
        [
          "--in",
          first,
          "--out",
          matrix_dir,
          "--campaign-ids",
          "current-run,frontier-run,historical-run"
        ] ++ rest
      )
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()

    assert matrix["summary"]["models"] == 3

    assert Enum.map(matrix["models"], & &1["model"]) == [
             "gpt-3.5-turbo-legacy",
             "gpt-5.4-mini",
             "gpt-5.5"
           ]
  end

  test "live matrix prefers latency-passing reruns at equal coverage" do
    out_dir = tmp_dir("live-matrix-latency-rerun")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    shared = %{
      "campaign_id" => "same-coverage",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "coverage" => %{"covered" => 1520, "expected" => 8724, "full" => false},
      "generation" => matched_effective_generation(),
      "tasks" => []
    }

    write_campaign_artifact(
      in_dir,
      "older-latency-fail.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:00:00Z",
        "parity" => %{
          "full_parity" => false,
          "latency_parity" => false,
          "aggregate_gap" => 0.005,
          "max_task_score_gap" => 0.018
        },
        "aggregate" => %{
          "imp_score" => 0.772,
          "dspy_score" => 0.778,
          "score_delta" => -0.006,
          "latency_ratio_imp_over_dspy" => 1.6
        }
      })
    )

    write_campaign_artifact(
      in_dir,
      "newer-latency-pass.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:01:00Z",
        "parity" => %{
          "full_parity" => false,
          "latency_parity" => true,
          "aggregate_gap" => 0.007,
          "max_task_score_gap" => 0.021
        },
        "aggregate" => %{
          "imp_score" => 0.771,
          "dspy_score" => 0.779,
          "score_delta" => -0.008,
          "latency_ratio_imp_over_dspy" => 1.35
        }
      })
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "same-coverage"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [model] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert model["artifact"]["path"] =~ "newer-latency-pass.json"
    assert model["parity"]["latency_parity"]
    assert model["latency"]["latency_ratio_imp_over_dspy"] == 1.35
  end

  test "live matrix prefers instrumented rerun over larger uninstrumented coverage" do
    out_dir = tmp_dir("live-matrix-instrumented-rerun")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    shared = %{
      "campaign_id" => "instrumented-rerun",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{
        "imp_score" => 0.8,
        "dspy_score" => 0.8,
        "score_delta" => 0.0,
        "latency_ratio_imp_over_dspy" => 1.2
      }
    }

    write_campaign_artifact(
      in_dir,
      "larger-uninstrumented.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:00:00Z",
        "coverage" => %{"covered" => 500, "expected" => 8724, "full" => false},
        "generation" => matched_effective_generation(),
        "tasks" => []
      })
    )

    write_campaign_artifact(
      in_dir,
      "smaller-instrumented.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:01:00Z",
        "coverage" => %{"covered" => 150, "expected" => 8724, "full" => false},
        "generation" => matched_effective_generation(),
        "tasks" => [
          %{
            "task" => "gsm8k",
            "imp_errors" => [],
            "dspy_errors" => [],
            "imp_instrumentation" => %{
              "coverage" => %{
                "instrumented_rows" => 75,
                "total_rows" => 75,
                "complete" => true
              },
              "lm_calls" => 75,
              "json_fallbacks" => 0,
              "parse_retries" => 0,
              "lm_duration_share" => %{"total" => 0.98}
            },
            "runtime_shape" => %{
              "coverage" => %{
                "total_rows" => 75,
                "message_chars_comparable_rows" => 75,
                "raw_chars_comparable_rows" => 75,
                "complete" => true
              },
              "message_chars_ratio_imp_over_dspy_mean" => 1.02,
              "raw_chars_ratio_imp_over_dspy_mean" => 0.22
            }
          },
          %{
            "task" => "hotpotqa",
            "imp_errors" => [],
            "dspy_errors" => [],
            "imp_instrumentation" => %{
              "coverage" => %{
                "instrumented_rows" => 75,
                "total_rows" => 75,
                "complete" => true
              },
              "lm_calls" => 75,
              "json_fallbacks" => 0,
              "parse_retries" => 0,
              "lm_duration_share" => %{"total" => 0.99}
            },
            "runtime_shape" => %{
              "coverage" => %{
                "total_rows" => 75,
                "message_chars_comparable_rows" => 75,
                "raw_chars_comparable_rows" => 75,
                "complete" => true
              },
              "message_chars_ratio_imp_over_dspy_mean" => 1.04,
              "raw_chars_ratio_imp_over_dspy_mean" => 0.24
            }
          }
        ]
      })
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "instrumented-rerun"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [model] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert model["artifact"]["path"] =~ "smaller-instrumented.json"
    assert model["coverage"]["covered"] == 150
    assert model["imp_instrumentation"]["coverage"]["complete"]
    assert model["runtime_shape"]["complete"]
  end

  test "live matrix prefers current prompt contract over larger obsolete reruns" do
    out_dir = tmp_dir("live-matrix-prompt-contract-rerun")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    shared = %{
      "campaign_id" => "prompt-contract-rerun",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{
        "imp_score" => 0.84,
        "dspy_score" => 0.84,
        "score_delta" => 0.0,
        "latency_ratio_imp_over_dspy" => 1.2
      }
    }

    obsolete_generation =
      put_in(
        matched_effective_generation(),
        ["value", "prompt_contract"],
        %{
          "imp_req_llm" => "imp-chat-template-v3-dspy-objective",
          "python_dspy" => "dspy-signature-chat-20260707"
        }
      )

    write_campaign_artifact(
      in_dir,
      "larger-obsolete-contract.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:00:00Z",
        "coverage" => %{"covered" => 350, "expected" => 8724, "full" => false},
        "generation" => obsolete_generation,
        "tasks" => instrumented_task_pair(175)
      })
    )

    write_campaign_artifact(
      in_dir,
      "smaller-current-contract.json",
      Map.merge(shared, %{
        "generated_at" => "2026-07-07T00:01:00Z",
        "coverage" => %{"covered" => 100, "expected" => 8724, "full" => false},
        "generation" => matched_effective_generation(),
        "tasks" => instrumented_task_pair(50)
      })
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "prompt-contract-rerun"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [model] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert model["artifact"]["path"] =~ "smaller-current-contract.json"
    assert model["coverage"]["covered"] == 100
    assert model["proof"]["prompt_contract_current"]
    assert model["proof"]["prompt_contract"] == current_prompt_contract()
  end

  test "live matrix summarizes latency parity and Imp transport settings" do
    out_dir = tmp_dir("live-matrix-latency-transport")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    generation =
      matched_effective_generation()
      |> put_in(
        ["value", "imp_transport"],
        %{"req_llm_pool" => %{"count" => 16, "protocols" => [:http1]}}
      )

    write_campaign_artifact(in_dir, "haiku-latency.json", %{
      "campaign_id" => "latency-transport",
      "provider" => "req_llm",
      "model" => "claude-haiku-4-5",
      "generated_at" => "2026-07-07T00:01:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "generation" => generation,
      "parity" => Map.put(sample_parity(), "latency_parity", false),
      "aggregate" => %{
        "imp_score" => 0.8,
        "dspy_score" => 0.8,
        "score_delta" => 0.0,
        "imp_duration_ms" => 162.0,
        "dspy_duration_ms" => 100.0,
        "latency_ratio_imp_over_dspy" => 1.62
      },
      "tasks" => instrumented_task_pair(100)
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "latency-transport"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    [model] = matrix["models"]

    refute matrix["summary"]["latency"]["complete"]
    assert matrix["summary"]["latency"]["failing_models"] == ["claude-haiku-4-5"]

    assert get_in(matrix, [
             "summary",
             "latency",
             "by_model",
             "claude-haiku-4-5",
             "ratio_imp_over_dspy"
           ]) == 1.62

    assert get_in(matrix, ["summary", "transport", "by_model", "claude-haiku-4-5"]) == %{
             "req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}
           }

    assert model["transport"] == %{
             "req_llm_pool" => %{"count" => 16, "protocols" => ["http1"]}
           }
  end

  test "live matrix lane summaries prefer current proof over stale larger low-cost coverage" do
    out_dir = tmp_dir("live-matrix-lane-current-proof-rank")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    obsolete_generation =
      put_in(
        matched_effective_generation(),
        ["value", "prompt_contract"],
        %{
          "imp_req_llm" => "imp-chat-template-v6-canonical-answer",
          "python_dspy" => "dspy-signature-chat-20260707-canonical-answer"
        }
      )

    shared = %{
      "provider" => "req_llm",
      "parity" => sample_parity(),
      "aggregate" => %{"imp_score" => 0.8, "dspy_score" => 0.8, "score_delta" => 0.0},
      "evidence_policy" => current_evidence_policy(),
      "tasks" => instrumented_task_pair(50)
    }

    write_campaign_artifact(
      in_dir,
      "larger-obsolete-mini.json",
      Map.merge(shared, %{
        "model" => "gpt-5.4-mini",
        "generated_at" => "2026-07-07T00:00:00Z",
        "coverage" => %{"covered" => 7930, "expected" => 8724, "full" => false},
        "generation" => obsolete_generation
      })
    )

    write_campaign_artifact(
      in_dir,
      "current-haiku.json",
      Map.merge(shared, %{
        "model" => "anthropic:claude-haiku-4-5",
        "generated_at" => "2026-07-07T00:01:00Z",
        "coverage" => %{"covered" => 1000, "expected" => 8724, "full" => false},
        "generation" => matched_effective_generation()
      })
    )

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    low_cost = matrix["summary"]["required_lanes"]["current_low_cost"]

    assert low_cost["best_model"] == "anthropic:claude-haiku-4-5"
    assert low_cost["coverage"]["best_model"] == "anthropic:claude-haiku-4-5"
    assert low_cost["coverage"]["covered_rows"] == 1000
    assert low_cost["coverage"]["remaining_rows"] == 7724
    refute low_cost["satisfied"]
  end

  test "live matrix freshness uses artifact generated_at before file mtime" do
    out_dir = tmp_dir("live-matrix-generated-at-freshness")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "stale-full.json", %{
      "campaign_id" => "stale-full",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2000-01-01T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "stale-full",
        "--max-age-hours",
        "1"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [mini] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    refute mini["fresh"]
    refute mini["full_evidence"]
    assert mini["proof"]["full_parity"]
  end

  test "live matrix refuses full evidence when wire API proof is mismatched" do
    out_dir = tmp_dir("live-matrix-wire-api-proof")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    mismatched_generation =
      put_in(
        matched_effective_generation(),
        ["effective", "wire_api_matched"],
        false
      )

    write_campaign_artifact(in_dir, "wire-mismatch-full.json", %{
      "campaign_id" => "wire-proof",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => mismatched_generation,
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "wire-proof"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [mini] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert mini["full_parity"]
    refute mini["full_evidence"]
    refute mini["proof"]["wire_api_matched"]
  end

  test "live matrix can isolate one campaign lineage" do
    out_dir = tmp_dir("live-matrix-campaign")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "old-campaign.json", %{
      "campaign_id" => "old-contract",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 190, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "fresh-campaign.json", %{
      "campaign_id" => "fresh-contract",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:01:00Z",
      "coverage" => %{"covered" => 120, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-id",
        "fresh-contract"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    [mini] = matrix["models"]

    assert matrix["campaign_id"] == "fresh-contract"
    assert mini["coverage"]["covered"] == 120
  end

  test "live matrix can validate an explicit multi-campaign lane set" do
    out_dir = tmp_dir("live-matrix-campaign-set")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "current.json", %{
      "campaign_id" => "current-run",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier.json", %{
      "campaign_id" => "frontier-run",
      "provider" => "req_llm",
      "model" => "gpt-5.5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "historical.json", %{
      "campaign_id" => "historical-run",
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo-legacy",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 200, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "unselected.json", %{
      "campaign_id" => "unselected-run",
      "provider" => "req_llm",
      "model" => "gpt-4.1",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir,
        "--campaign-ids",
        "current-run,frontier-run,historical-run"
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    required = matrix["summary"]["required_lanes"]

    assert matrix["campaign_id"] == nil
    assert matrix["campaign_ids"] == ["current-run", "frontier-run", "historical-run"]

    assert Enum.map(matrix["models"], & &1["model"]) == [
             "gpt-3.5-turbo-legacy",
             "gpt-5.4-mini",
             "gpt-5.5"
           ]

    assert required["current_low_cost"]["present"]
    assert required["frontier_sanity"]["present"]
    assert required["historical_research"]["present"]
    refute Enum.any?(matrix["models"], &(&1["model"] == "gpt-4.1"))
  end

  test "live matrix can isolate campaign lineage from environment" do
    out_dir = tmp_dir("live-matrix-env-campaign")
    in_dir = Path.join(out_dir, "campaigns")
    matrix_dir = Path.join(out_dir, "matrix")
    File.mkdir_p!(in_dir)

    write_campaign_artifact(in_dir, "old-campaign.json", %{
      "campaign_id" => "old-contract",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 190, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "fresh-campaign.json", %{
      "campaign_id" => "fresh-contract",
      "provider" => "req_llm",
      "model" => "gpt-5.4-mini",
      "generated_at" => "2026-07-07T00:01:00Z",
      "coverage" => %{"covered" => 120, "expected" => 8724, "full" => false},
      "parity" => %{"full_parity" => false, "latency_parity" => true},
      "aggregate" => %{"imp_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    previous = System.get_env("IMP_BENCH_CAMPAIGN_ID")
    System.put_env("IMP_BENCH_CAMPAIGN_ID", "fresh-contract")

    try do
      capture_io(fn ->
        Mix.Tasks.Imp.Benchmark.LiveMatrix.run([
          "--in",
          Path.join(in_dir, "*.json"),
          "--out",
          matrix_dir
        ])
      end)
    after
      if previous,
        do: System.put_env("IMP_BENCH_CAMPAIGN_ID", previous),
        else: System.delete_env("IMP_BENCH_CAMPAIGN_ID")
    end

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    matrix = matrix_path |> File.read!() |> Jason.decode!()
    [mini] = matrix["models"]

    assert matrix["campaign_id"] == "fresh-contract"
    assert mini["coverage"]["covered"] == 120
  end

  defp read_jsonl(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-benchmark-truth-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp gsm8k_hf_row(index) do
    %{
      "row" => %{
        "question" => "What is #{index}+0?",
        "answer" => "Compute #{index}+0. #### #{index}"
      }
    }
  end

  defp write_parity_report(out_dir, name, generated_at, offset, passes, opts \\ []) do
    provider = Keyword.get(opts, :provider, "req_llm")
    campaign_id = Keyword.get(opts, :campaign_id)

    rows =
      passes
      |> Enum.with_index()
      |> Enum.map(fn {passed?, index} ->
        %{
          "index" => index,
          "absolute_index" => offset + index,
          "imp_passed" => passed?,
          "dspy_passed" => passed?,
          "pass_agreement" => true,
          "answer_agreement" => true,
          "imp_answer" => to_string(offset + index),
          "dspy_answer" => to_string(offset + index),
          "imp_duration_ms" => 20.0,
          "dspy_duration_ms" => 10.0,
          "imp_instrumentation" => %{
            "lm_calls" => 1,
            "lm_duration_ms" => 18.0,
            "json_fallbacks" => 0,
            "parse_retries" => 0,
            "message_chars" => 100 + offset + index,
            "raw_chars" => 50 + offset + index
          },
          "dspy_instrumentation" => %{
            "lm_calls" => 1,
            "lm_duration_ms" => 9.0,
            "input_chars" => 80 + offset + index,
            "message_chars" => 200 + 2 * (offset + index),
            "raw_chars" => 100 + 2 * (offset + index),
            "prediction_chars" => 40 + offset + index,
            "history_found" => true
          }
        }
      end)

    report = %{
      "schema_version" => 1,
      "generated_at" => generated_at,
      "campaign_id" => campaign_id,
      "imp" => %{"model" => %{"provider" => provider, "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" =>
        Keyword.get(opts, :generation, %{"temperature" => 0.0, "max_tokens" => 700}),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => offset,
          "examples" => length(rows),
          "max_concurrency" => Keyword.get(opts, :max_concurrency, 1),
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp complete_row(index, passed?) do
    %{
      "index" => index,
      "absolute_index" => index,
      "imp_row_present" => true,
      "dspy_row_present" => true,
      "row_evidence_complete" => true,
      "imp_passed" => passed?,
      "dspy_passed" => passed?,
      "pass_agreement" => true,
      "answer_agreement" => true,
      "imp_answer" => to_string(index),
      "dspy_answer" => to_string(index),
      "imp_duration_ms" => 20.0,
      "dspy_duration_ms" => 10.0
    }
  end

  defp write_parity_rows(out_dir, name, rows) do
    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => nil,
      "imp" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => 0,
          "examples" => length(rows),
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_hotpotqa_parity_report(out_dir, name, rows_spec) do
    rows =
      rows_spec
      |> Enum.with_index()
      |> Enum.map(fn {{imp_passed?, dspy_passed?, imp_f1, dspy_f1}, index} ->
        %{
          "index" => index,
          "absolute_index" => index,
          "imp_passed" => imp_passed?,
          "dspy_passed" => dspy_passed?,
          "pass_agreement" => imp_passed? == dspy_passed?,
          "answer_agreement" => imp_passed? and dspy_passed?,
          "imp_answer" => "answer #{index}",
          "dspy_answer" => "answer #{index}",
          "imp_duration_ms" => 20.0,
          "dspy_duration_ms" => 10.0,
          "imp_metric_metadata" => %{"official_hotpotqa_f1" => imp_f1},
          "dspy_metric_metadata" => %{"official_hotpotqa_f1" => dspy_f1}
        }
      end)

    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => nil,
      "imp" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "hotpotqa",
          "offset" => 0,
          "examples" => length(rows),
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_hotpotqa_analysis_report(out_dir, name, opts \\ []) do
    rows = [
      %{
        "index" => 0,
        "absolute_index" => 0,
        "imp_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "imp_answer" => "$10.5 million USD",
        "dspy_answer" => "$10.5 million",
        "imp_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "imp_metric_metadata" => %{"official_hotpotqa_f1" => 0.8},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 1.0}
      },
      %{
        "index" => 1,
        "absolute_index" => 1,
        "imp_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "imp_answer" => "Both are magazines.",
        "dspy_answer" => "yes",
        "imp_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "imp_metric_metadata" => %{"official_hotpotqa_f1" => 0.0},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 1.0}
      },
      %{
        "index" => 2,
        "absolute_index" => 2,
        "imp_passed" => true,
        "dspy_passed" => false,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "imp_answer" => "Paris France",
        "dspy_answer" => "Paris",
        "imp_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "imp_metric_metadata" => %{"official_hotpotqa_f1" => 1.0},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 0.5}
      }
    ]

    rows = rows ++ Keyword.get(opts, :extra_rows, [])
    extra_task_fields = Keyword.get(opts, :extra_task_fields, %{})

    task =
      Map.merge(
        %{
          "task" => "hotpotqa",
          "offset" => 0,
          "examples" => length(rows),
          "imp_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        },
        extra_task_fields
      )

    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => "analysis-run",
      "imp" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [task],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_campaign_artifact(out_dir, name, artifact) do
    artifact =
      artifact
      |> Map.put_new("evidence_policy", current_evidence_policy())
      |> Map.put_new("execution", %{
        "max_concurrency_values" => [1],
        "max_concurrency" => 1,
        "max_concurrency_consistent" => true
      })

    File.write!(Path.join(out_dir, name), Jason.encode!(artifact, pretty: true) <> "\n")
  end

  defp write_json!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n")

  defp write_legacy_campaign_artifact(out_dir, name, artifact) do
    artifact = Map.put_new(artifact, "evidence_policy", current_evidence_policy())
    File.write!(Path.join(out_dir, name), Jason.encode!(artifact, pretty: true) <> "\n")
  end

  defp matched_effective_generation do
    %{
      "consistent" => true,
      "value" => %{
        "temperature" => 0.0,
        "max_tokens" => 700,
        "prompt_contract" => current_prompt_contract()
      },
      "effective" => %{
        "complete" => true,
        "matched" => true,
        "imp_recorded_count" => 1,
        "dspy_recorded_count" => 1,
        "imp_distinct" => [%{"temperature" => 0.0, "max_tokens" => 700}],
        "dspy_distinct" => [%{"temperature" => 0.0, "max_tokens" => 700}],
        "wire_api_complete" => true,
        "wire_api_matched" => true,
        "imp_wire_api_recorded_count" => 1,
        "dspy_wire_api_recorded_count" => 1,
        "imp_wire_api_distinct" => ["openai_chat_completions"],
        "dspy_wire_api_distinct" => ["openai_chat_completions"]
      }
    }
  end

  defp sample_parity do
    %{
      "full_parity" => false,
      "full_coverage" => false,
      "latency_parity" => true,
      "aggregate_gap" => 0.0,
      "max_task_score_gap" => 0.0,
      "strict_aggregate_gap" => 0.01,
      "strict_task_gap" => 0.01
    }
  end

  defp current_prompt_contract do
    Imp.BenchmarkTruth.Contract.current_prompt_contract()
  end

  defp current_evidence_policy do
    %{
      "version" => 2,
      "runner_error_rows" => "incomplete",
      "answerless_unindexed_runner_errors" => "incomplete",
      "newer_incomplete_overwrites_complete" => false,
      "coverage_unit" => "accepted_complete_row"
    }
  end

  defp instrumented_task_pair(rows_per_task) do
    Enum.map(["gsm8k", "hotpotqa"], fn task ->
      %{
        "task" => task,
        "imp_errors" => [],
        "dspy_errors" => [],
        "imp_instrumentation" => %{
          "coverage" => %{
            "instrumented_rows" => rows_per_task,
            "total_rows" => rows_per_task,
            "complete" => true
          },
          "lm_calls" => rows_per_task,
          "json_fallbacks" => 0,
          "parse_retries" => 0,
          "lm_duration_share" => %{"total" => 0.98}
        },
        "runtime_shape" => %{
          "coverage" => %{
            "total_rows" => rows_per_task,
            "message_chars_comparable_rows" => rows_per_task,
            "raw_chars_comparable_rows" => rows_per_task,
            "complete" => true
          },
          "message_chars_ratio_imp_over_dspy_mean" => 1.02,
          "raw_chars_ratio_imp_over_dspy_mean" => 0.22
        }
      }
    end)
  end
end
