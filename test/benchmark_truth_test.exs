defmodule BenchmarkTruthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias DSEx.BenchmarkTruth.Fetcher

  @fixtures Path.expand("fixtures/benchmarks", __DIR__)

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
      DSEx.BenchmarkTruth.fetch(["gsm8k"],
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

  test "fetcher paginates full-size requests and records source pages" do
    out_dir = tmp_dir("fetch-pages")
    parent = self()

    [result] =
      DSEx.BenchmarkTruth.fetch(["gsm8k"],
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
    assert DSEx.BenchmarkTruth.current_prompt_contract() == current_prompt_contract()
    assert DSEx.BenchmarkTruth.Contract.hotpotqa_instruction() =~ "canonical exact answer span"
    assert DSEx.BenchmarkTruth.Contract.hotpotqa_instruction() =~ "Do not abbreviate locations"
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
      DSEx.BenchmarkTruth.run(
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

  test "benchmark truth rows include compact diagnostics for failed predictions" do
    out_dir = tmp_dir("diagnostic-results")

    result =
      DSEx.BenchmarkTruth.run(
        tasks: [hotpotqa: Path.join(@fixtures, "hotpotqa-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: DSEx.LM.Static,
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
    assert system["content"] =~ "Must be a concise exact answer span"
    assert system["content"] =~ "For yes/no questions, answer exactly yes or no."
    assert system["content"] =~ "Return the canonical exact answer span from the context."
    assert system["content"] =~ "Do not abbreviate locations, titles, names, dates, or quantities"
    assert row["metric_metadata"]["task_metric"] == "hotpotqa_exact_match"
    assert row["metric_metadata"]["official_hotpotqa_em"] == false
    assert is_number(row["metric_metadata"]["official_hotpotqa_f1"])
  end

  test "benchmark truth diagnostics include traces for adapter parse failures" do
    out_dir = tmp_dir("parse-failure-diagnostics")

    result =
      DSEx.BenchmarkTruth.run(
        tasks: [gsm8k: Path.join(@fixtures, "gsm8k-small.jsonl")],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: DSEx.LM.Static,
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

  test "benchmark truth rows include DSEx runtime instrumentation" do
    out_dir = tmp_dir("instrumented-results")

    lm = DSEx.req_llm("openai:gpt-test", test_pid: self(), req_module: ReqLLMStub)

    result =
      DSEx.BenchmarkTruth.run(
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
      DSEx.BenchmarkTruth.run(
        tasks: [gsm8k: path],
        out_dir: out_dir,
        max_examples: 1,
        lm: %{
          module: DSEx.LM.Static,
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
      DSEx.BenchmarkTruth.run(
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

    result = DSEx.BenchmarkTruth.integrity([hotpotqa: path], out_dir: out_dir)
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
      DSEx.BenchmarkTruth.integrity(
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
             Mix.Tasks.Dsex.Benchmark.Parity.parse_dspy_report_path("""
             warning: wrote debug.json
             DSPY_REPORT_PATH=benchmarks/results/report.json
             aggregate score: 1.0
             """)

    assert :error =
             Mix.Tasks.Dsex.Benchmark.Parity.parse_dspy_report_path("""
             warning: this line ends in debug.json
             aggregate score: 1.0
             """)
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
        {"messages": [{"content": "Question: alpha?"}], "response": {"answer": "A"}},
        {"messages": [{"content": "Question: beta?"}], "response": {"answer": "B"}},
    ])

    assert runner.attributed_history_entry(0, {"question": "beta?"})["response"]["answer"] == "B"
    assert runner.attributed_history_entry(1, {"question": "anything"})["response"]["answer"] == "B"
    assert runner.attributed_history_entry(0, {"question": "missing?"}) is None

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

  test "parity task parses reasoning effort option" do
    assert {[reasoning_effort: "low"], [], []} =
             Mix.Tasks.Dsex.Benchmark.Parity.parse_args(["--reasoning-effort", "low"])

    generation_opts =
      Mix.Tasks.Dsex.Benchmark.Parity.generation_opts(
        reasoning_effort: "low",
        temperature: 0.0,
        max_tokens: 700
      )

    assert Keyword.fetch!(generation_opts, :temperature) == 0.0
    assert Keyword.fetch!(generation_opts, :max_tokens) == 700
    assert Keyword.fetch!(generation_opts, :reasoning_effort) == "low"
  end

  test "parity aggregate deduplicates overlapping chunks and reports coverage gaps" do
    out_dir = tmp_dir("parity-aggregate")
    write_parity_report(out_dir, "older.json", "2026-07-06T00:00:00Z", 0, [true, false])
    write_parity_report(out_dir, "newer.json", "2026-07-06T00:01:00Z", 1, [true, true])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
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
    assert gsm8k["dsex_passes"] == 3
    assert gsm8k["dspy_passes"] == 3
    assert gsm8k["row_latency"]["dsex"]["count"] == 3
    assert gsm8k["row_latency"]["dspy"]["count"] == 3
    assert gsm8k["row_latency"]["ratio_dsex_over_dspy"]["mean"] == 2.0
    assert gsm8k["dsex_instrumentation"]["coverage"]["instrumented_rows"] == 3
    assert gsm8k["dsex_instrumentation"]["coverage"]["complete"]
    assert gsm8k["dsex_instrumentation"]["lm_calls"] == 3
    assert gsm8k["dsex_instrumentation"]["json_fallbacks"] == 0
    assert gsm8k["dsex_instrumentation"]["parse_retries"] == 0
    assert gsm8k["dsex_instrumentation"]["lm_duration"]["mean_ms"] == 18.0
    assert gsm8k["dsex_instrumentation"]["local_overhead_ms"]["mean_ms"] == 2.0
    assert gsm8k["dsex_instrumentation"]["lm_duration_share"]["mean"] == 0.9
    assert gsm8k["dsex_instrumentation"]["message_chars"]["mean_chars"] == 101.0
    assert gsm8k["dsex_instrumentation"]["message_chars"]["p90_chars"] == 102
    assert gsm8k["dsex_instrumentation"]["raw_chars"]["mean_chars"] == 51.0
    assert gsm8k["dspy_instrumentation"]["coverage"]["instrumented_rows"] == 3
    assert gsm8k["dspy_instrumentation"]["coverage"]["complete"]
    assert gsm8k["dspy_instrumentation"]["lm_calls"] == 3
    assert gsm8k["dspy_instrumentation"]["input_chars"]["mean_chars"] == 81.0
    assert gsm8k["runtime_shape"]["message_chars_ratio_dsex_over_dspy_mean"] == 0.5
    assert gsm8k["runtime_shape"]["raw_chars_ratio_dsex_over_dspy_mean"] == 0.5

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
        "dsex" => %{
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
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    effective = campaign["generation"]["effective"]

    assert effective["complete"]
    assert effective["matched"]
    assert effective["wire_api_complete"]
    refute effective["wire_api_matched"]
    assert effective["dsex_wire_api_distinct"] == ["openai_responses"]
    assert effective["dspy_wire_api_distinct"] == ["litellm_chat_completion"]
    refute campaign["parity"]["full_parity"]
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
        "dsex" => %{
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
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))

    effective =
      campaign_path |> File.read!() |> Jason.decode!() |> get_in(["generation", "effective"])

    assert effective["wire_api_complete"]
    assert effective["wire_api_matched"]
    assert effective["dsex_wire_api_distinct"] == ["openai_chat_completions"]
    assert effective["dspy_wire_api_distinct"] == ["litellm_chat_completion"]

    assert effective["dsex_wire_endpoint_families"] == ["openai_chat_completions"]
    assert effective["dspy_wire_endpoint_families"] == ["openai_chat_completions"]
  end

  test "parity aggregate marks runtime shape incomplete when DSPy history is partial" do
    out_dir = tmp_dir("parity-aggregate-partial-runtime-shape")

    write_parity_rows(out_dir, "partial-runtime-shape.json", [
      complete_row(0, true)
      |> put_in(["dsex_instrumentation"], %{"message_chars" => 100, "raw_chars" => 50})
      |> put_in(["dspy_instrumentation"], %{"message_chars" => 200, "raw_chars" => 100}),
      complete_row(1, true)
      |> put_in(["dsex_instrumentation"], %{"message_chars" => 300, "raw_chars" => 150})
      |> put_in(["dspy_instrumentation"], %{"raw_chars" => 300})
    ])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["runtime_shape"]["message_chars_ratio_dsex_over_dspy_mean"] == 0.5
    assert gsm8k["runtime_shape"]["raw_chars_ratio_dsex_over_dspy_mean"] == 0.5

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
      |> put_in(["dsex_instrumentation"], %{"message_chars" => 100, "raw_chars" => 50})
      |> put_in(["dspy_instrumentation"], %{
        "message_chars" => 200,
        "message_chars_source" => "lm_history",
        "raw_chars" => 100,
        "raw_chars_source" => "lm_history",
        "history_found" => true
      }),
      complete_row(1, true)
      |> put_in(["dsex_instrumentation"], %{"message_chars" => 300, "raw_chars" => 150})
      |> put_in(["dspy_instrumentation"], %{
        "message_chars" => 300,
        "message_chars_source" => "row_estimate",
        "raw_chars" => 75,
        "raw_chars_source" => "prediction_fallback",
        "history_found" => false
      })
    ])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
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
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
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
        "dsex_row_present" => true,
        "dspy_row_present" => false,
        "row_evidence_complete" => false,
        "dsex_passed" => true,
        "dspy_passed" => nil,
        "pass_agreement" => nil,
        "answer_agreement" => nil,
        "dsex_answer" => "0",
        "dspy_answer" => nil
      }
    ])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["coverage"]["covered"] == 0
    assert gsm8k["coverage"]["incomplete_rows"] == 1
    assert [%{"from" => 0, "to" => 1318}] = gsm8k["coverage"]["missing_ranges"]
    assert gsm8k["dsex_passes"] == 0
    assert gsm8k["dspy_passes"] == 0
    refute campaign["coverage"]["full"]
    refute campaign["parity"]["full_parity"]
  end

  test "parity aggregate refuses to mix provider identities" do
    out_dir = tmp_dir("parity-aggregate-provider")

    write_parity_report(out_dir, "req.json", "2026-07-06T00:00:00Z", 0, [true],
      provider: "req_llm"
    )

    write_parity_report(out_dir, "direct.json", "2026-07-06T00:01:00Z", 1, [true],
      provider: "openai-compatible"
    )

    assert_raise Mix.Error, ~r/requires one DSEx provider\/model identity/, fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
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

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
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
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
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

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
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
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    hotpotqa = Enum.find(campaign["tasks"], &(&1["task"] == "hotpotqa"))

    assert hotpotqa["score_delta"] == -0.5

    assert %{
             "dsex" => 0.75,
             "dspy" => 1.0,
             "delta" => -0.25,
             "coverage" => %{"dsex_rows" => 2, "dspy_rows" => 2, "total_rows" => 2}
           } = hotpotqa["supporting_metrics"]["official_hotpotqa_f1"]
  end

  test "parity aggregate carries bounded disagreement examples for engineering triage" do
    out_dir = tmp_dir("parity-aggregate-disagreements")

    write_parity_rows(out_dir, "disagreements.json", [
      complete_row(0, true),
      %{
        "index" => 1,
        "absolute_index" => 1,
        "dsex_row_present" => true,
        "dspy_row_present" => true,
        "row_evidence_complete" => true,
        "dsex_passed" => true,
        "dspy_passed" => false,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "dsex_answer" => "Robert Boyle",
        "dspy_answer" => "Boyle",
        "dsex_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "dsex_metric_metadata" => %{
          "official_hotpotqa_f1" => 1.0,
          "normalized_prediction" => "robert boyle"
        },
        "dspy_metric_metadata" => %{
          "official_hotpotqa_f1" => 0.5,
          "normalized_prediction" => "boyle"
        },
        "diagnostic" => %{
          "dsex" => %{
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
        "dsex_row_present" => true,
        "dspy_row_present" => true,
        "row_evidence_complete" => true,
        "dsex_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "dsex_answer" => "yes, because both are magazines",
        "dspy_answer" => "yes",
        "dsex_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0
      }
    ])

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.Parity.Aggregate.run([
        "--in",
        Path.join(out_dir, "*.json"),
        "--out",
        out_dir,
        "--model",
        "gpt-test"
      ])
    end)

    [campaign_path] = Path.wildcard(Path.join(out_dir, "dsex-dspy-parity-campaign-*.json"))
    campaign = campaign_path |> File.read!() |> Jason.decode!()
    gsm8k = Enum.find(campaign["tasks"], &(&1["task"] == "gsm8k"))

    assert gsm8k["disagreements"]["count"] == 2
    assert gsm8k["disagreements"]["pass_disagreements"] == 2
    assert gsm8k["disagreements"]["answer_disagreements"] == 2

    assert gsm8k["disagreements"]["directions"] == %{
             "dsex_only_pass" => 1,
             "dspy_only_pass" => 1
           }

    [first, second] = gsm8k["disagreements"]["examples"]
    assert first["absolute_index"] == 1
    assert first["direction"] == "dsex_only_pass"
    assert first["dsex_answer"] == "Robert Boyle"
    assert first["dspy_answer"] == "Boyle"
    assert first["source_report"] =~ "disagreements.json"
    assert first["dsex_metric_metadata"]["official_hotpotqa_f1"] == 1.0
    assert first["diagnostic"]["dsex"]["question"] == "Who discovered the law?"
    assert first["diagnostic"]["dsex"]["gold_answer"] == "Robert Boyle"
    assert first["diagnostic"]["dsex"]["context_length"] == 1234
    refute Map.has_key?(first["diagnostic"]["dsex"], "trace")

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

    write_hotpotqa_analysis_report(out_dir, "dsex-dspy-parity-directory.json")

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.HotpotqaAnalysis.run([
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
    assert analysis["summary"]["dsex_passes"] == 1
    assert analysis["summary"]["dspy_passes"] == 2
    assert analysis["directions"]["dspy_only_pass"] == 2

    assert analysis["categories"]["dsex_overlong_span"] == 1
    assert analysis["categories"]["dsex_yes_no_explanation"] == 1
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

    write_hotpotqa_analysis_report(out_dir, "dsex-dspy-parity-directory.json")

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.HotpotqaAnalysis.run([
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
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.next_chunk_plan(aggregate, %{
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
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.next_chunk_plan(aggregate, %{
               gsm8k: "gsm8k.jsonl"
             })
  end

  test "campaign chunk args preserve endpoint-equivalent DSPy route" do
    args =
      Mix.Tasks.Dsex.Benchmark.Parity.Campaign.chunk_args(
        [
          dspy_model: "responses/gpt-5.4-mini",
          chunk_size: 50,
          max_concurrency: 8,
          temperature: 0.0,
          max_tokens: 700,
          reasoning_effort: "low"
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

    assert Enum.at(args, reasoning_effort_index + 1) == "low"
    assert "--model" in args
    assert "--runner-order" in args
    assert "--gsm8k" in args
  end

  test "campaign target coverage shrinks chunk size to the next useful live slice" do
    aggregate = %{"coverage" => %{"covered" => 90}}

    two_task_plan = [
      %{task: :gsm8k, path: "gsm8k.jsonl", offset: 45, remaining: 1274},
      %{task: :hotpotqa, path: "hotpotqa.jsonl", offset: 45, remaining: 7360}
    ]

    assert 5 =
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.planned_chunk_size(
               aggregate,
               two_task_plan,
               chunk_size: 50,
               target_coverage: 100
             )

    assert 50 =
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.planned_chunk_size(
               aggregate,
               two_task_plan,
               chunk_size: 50,
               target_coverage: 1000
             )

    assert 1 =
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.planned_chunk_size(
               %{"coverage" => %{"covered" => 100}},
               two_task_plan,
               chunk_size: 50,
               target_coverage: 100
             )

    assert 2 =
             Mix.Tasks.Dsex.Benchmark.Parity.Campaign.planned_chunk_size(
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
      "aggregate" => %{"dsex_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "dsex_errors" => [],
          "dspy_errors" => [],
          "dsex_instrumentation" => %{
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
            "message_chars_ratio_dsex_over_dspy_mean" => 1.1,
            "raw_chars_ratio_dsex_over_dspy_mean" => 0.25
          },
          "disagreements" => %{
            "count" => 2,
            "pass_disagreements" => 1,
            "answer_disagreements" => 2,
            "directions" => %{"dsex_only_pass" => 1, "answer_or_evidence_mismatch" => 1},
            "examples" => [
              %{
                "absolute_index" => 1,
                "direction" => "dsex_only_pass",
                "dsex_answer" => "yes",
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
      "aggregate" => %{"dsex_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "historical.json", %{
      "provider" => "req_llm",
      "model" => "gpt-3.5-turbo-legacy",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"dsex_score" => 0.9, "dspy_score" => 0.9, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    write_campaign_artifact(in_dir, "frontier-without-effective-generation.json", %{
      "provider" => "req_llm",
      "model" => "gpt-5.5",
      "generated_at" => "2026-07-07T00:00:00Z",
      "coverage" => %{"covered" => 8724, "expected" => 8724, "full" => true},
      "parity" => %{"full_parity" => true, "latency_parity" => true},
      "aggregate" => %{"dsex_score" => 0.9, "dspy_score" => 0.9, "score_delta" => 0.0},
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
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
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
    refute required["frontier_sanity"]["full_evidence"]
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
    assert mini["disagreements"]["directions"]["dsex_only_pass"] == 1
    assert [%{"task" => "gsm8k", "absolute_index" => 1}] = mini["disagreements"]["examples"]
    assert matrix["summary"]["disagreements"]["count"] == 2
    assert matrix["summary"]["disagreements"]["by_model"]["gpt-5.4-mini"]["count"] == 2
    assert mini["lane_tags"] == ["current_low_cost"]
    assert mini["proof"]["prompt_contract_current"]
    assert mini["dsex_instrumentation"]["coverage"]["complete"]
    assert mini["dsex_instrumentation"]["coverage"]["instrumented_rows"] == 20
    assert mini["dsex_instrumentation"]["lm_calls"] == 20
    assert mini["dsex_instrumentation"]["json_fallbacks"] == 1
    assert mini["dsex_instrumentation"]["dominant_latency_source"] == "provider_model"
    assert mini["dsex_instrumentation"]["max_local_overhead_mean_ms"] == 3.5
    assert mini["runtime_shape"]["complete"]
    assert mini["runtime_shape"]["coverage"]["complete"]
    assert mini["runtime_shape"]["coverage"]["message_chars_comparable_rows"] == 20
    assert mini["runtime_shape"]["tasks_with_runtime_shape"] == 1
    assert mini["runtime_shape"]["message_chars_ratio_dsex_over_dspy_mean"] == 1.1
    assert mini["runtime_shape"]["raw_chars_ratio_dsex_over_dspy_mean"] == 0.25
    assert matrix["summary"]["dsex_instrumentation"]["models_with_complete_instrumentation"] == 1
    assert matrix["summary"]["dsex_instrumentation"]["total_models"] == 3
    refute matrix["summary"]["dsex_instrumentation"]["complete"]
    assert matrix["summary"]["runtime_shape"]["models_with_runtime_shape"] == 1
    assert matrix["summary"]["runtime_shape"]["models_with_complete_runtime_shape"] == 1
    assert matrix["summary"]["runtime_shape"]["total_models"] == 3
    assert matrix["summary"]["runtime_shape"]["mean_message_chars_ratio_dsex_over_dspy"] == 1.1
    assert matrix["summary"]["runtime_shape"]["mean_raw_chars_ratio_dsex_over_dspy"] == 0.25
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

  test "live matrix prefers wider coverage over narrower complete runtime-shape diagnostics" do
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
      "aggregate" => %{"dsex_score" => 0.84, "dspy_score" => 0.846, "score_delta" => -0.006},
      "generation" => matched_effective_generation(),
      "tasks" => [
        %{
          "task" => "hotpotqa",
          "dsex_errors" => [],
          "dspy_errors" => [],
          "dsex_instrumentation" => %{
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
            "message_chars_ratio_dsex_over_dspy_mean" => 1.05,
            "raw_chars_ratio_dsex_over_dspy_mean" => 0.27
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
      "aggregate" => %{"dsex_score" => 0.91, "dspy_score" => 0.91, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => instrumented_task_pair(6)
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
        "--in",
        Path.join(in_dir, "*.json"),
        "--out",
        matrix_dir
      ])
    end)

    [matrix_path] = Path.wildcard(Path.join(matrix_dir, "live-matched-model-matrix-*.json"))
    [mini] = matrix_path |> File.read!() |> Jason.decode!() |> Map.fetch!("models")

    assert mini["coverage"]["covered"] == 300
    assert mini["artifact"]["path"] =~ "wide-partial-shape.json"
    refute mini["runtime_shape"]["complete"]
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    [first | rest] = in_dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run(
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
          "dsex_score" => 0.772,
          "dspy_score" => 0.778,
          "score_delta" => -0.006,
          "latency_ratio_dsex_over_dspy" => 1.6
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
          "dsex_score" => 0.771,
          "dspy_score" => 0.779,
          "score_delta" => -0.008,
          "latency_ratio_dsex_over_dspy" => 1.35
        }
      })
    )

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
    assert model["latency"]["latency_ratio_dsex_over_dspy"] == 1.35
  end

  test "live matrix keeps larger coverage visible even when diagnostics are partial" do
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
        "dsex_score" => 0.8,
        "dspy_score" => 0.8,
        "score_delta" => 0.0,
        "latency_ratio_dsex_over_dspy" => 1.2
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
            "dsex_errors" => [],
            "dspy_errors" => [],
            "dsex_instrumentation" => %{
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
              "message_chars_ratio_dsex_over_dspy_mean" => 1.02,
              "raw_chars_ratio_dsex_over_dspy_mean" => 0.22
            }
          },
          %{
            "task" => "hotpotqa",
            "dsex_errors" => [],
            "dspy_errors" => [],
            "dsex_instrumentation" => %{
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
              "message_chars_ratio_dsex_over_dspy_mean" => 1.04,
              "raw_chars_ratio_dsex_over_dspy_mean" => 0.24
            }
          }
        ]
      })
    )

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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

    assert model["artifact"]["path"] =~ "larger-uninstrumented.json"
    assert model["coverage"]["covered"] == 500
    refute model["dsex_instrumentation"]["coverage"]["complete"]
    refute model["runtime_shape"]["complete"]
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
        "dsex_score" => 0.84,
        "dspy_score" => 0.84,
        "score_delta" => 0.0,
        "latency_ratio_dsex_over_dspy" => 1.2
      }
    }

    obsolete_generation =
      put_in(
        matched_effective_generation(),
        ["value", "prompt_contract"],
        %{
          "dsex_req_llm" => "dsex-chat-template-v3-dspy-objective",
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
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
      "aggregate" => %{"dsex_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
      "aggregate" => %{"dsex_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => mismatched_generation,
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
      "aggregate" => %{"dsex_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 1.0, "dspy_score" => 1.0, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    capture_io(fn ->
      Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
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
      "aggregate" => %{"dsex_score" => 0.5, "dspy_score" => 0.5, "score_delta" => 0.0},
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
      "aggregate" => %{"dsex_score" => 0.7, "dspy_score" => 0.7, "score_delta" => 0.0},
      "generation" => matched_effective_generation(),
      "tasks" => []
    })

    previous = System.get_env("DSEX_BENCH_CAMPAIGN_ID")
    System.put_env("DSEX_BENCH_CAMPAIGN_ID", "fresh-contract")

    try do
      capture_io(fn ->
        Mix.Tasks.Dsex.Benchmark.LiveMatrix.run([
          "--in",
          Path.join(in_dir, "*.json"),
          "--out",
          matrix_dir
        ])
      end)
    after
      if previous,
        do: System.put_env("DSEX_BENCH_CAMPAIGN_ID", previous),
        else: System.delete_env("DSEX_BENCH_CAMPAIGN_ID")
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
        "dsex-benchmark-truth-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

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
          "dsex_passed" => passed?,
          "dspy_passed" => passed?,
          "pass_agreement" => true,
          "answer_agreement" => true,
          "dsex_answer" => to_string(offset + index),
          "dspy_answer" => to_string(offset + index),
          "dsex_duration_ms" => 20.0,
          "dspy_duration_ms" => 10.0,
          "dsex_instrumentation" => %{
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
      "dsex" => %{"model" => %{"provider" => provider, "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" =>
        Keyword.get(opts, :generation, %{"temperature" => 0.0, "max_tokens" => 700}),
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => offset,
          "examples" => length(rows),
          "dsex_duration_ms" => 10.0,
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
      "dsex_row_present" => true,
      "dspy_row_present" => true,
      "row_evidence_complete" => true,
      "dsex_passed" => passed?,
      "dspy_passed" => passed?,
      "pass_agreement" => true,
      "answer_agreement" => true,
      "dsex_answer" => to_string(index),
      "dspy_answer" => to_string(index),
      "dsex_duration_ms" => 20.0,
      "dspy_duration_ms" => 10.0
    }
  end

  defp write_parity_rows(out_dir, name, rows) do
    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => nil,
      "dsex" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "gsm8k",
          "offset" => 0,
          "examples" => length(rows),
          "dsex_duration_ms" => 10.0,
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
      |> Enum.map(fn {{dsex_passed?, dspy_passed?, dsex_f1, dspy_f1}, index} ->
        %{
          "index" => index,
          "absolute_index" => index,
          "dsex_passed" => dsex_passed?,
          "dspy_passed" => dspy_passed?,
          "pass_agreement" => dsex_passed? == dspy_passed?,
          "answer_agreement" => dsex_passed? and dspy_passed?,
          "dsex_answer" => "answer #{index}",
          "dspy_answer" => "answer #{index}",
          "dsex_duration_ms" => 20.0,
          "dspy_duration_ms" => 10.0,
          "dsex_metric_metadata" => %{"official_hotpotqa_f1" => dsex_f1},
          "dspy_metric_metadata" => %{"official_hotpotqa_f1" => dspy_f1}
        }
      end)

    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => nil,
      "dsex" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "hotpotqa",
          "offset" => 0,
          "examples" => length(rows),
          "dsex_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_hotpotqa_analysis_report(out_dir, name) do
    rows = [
      %{
        "index" => 0,
        "absolute_index" => 0,
        "dsex_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "dsex_answer" => "$10.5 million USD",
        "dspy_answer" => "$10.5 million",
        "dsex_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "dsex_metric_metadata" => %{"official_hotpotqa_f1" => 0.8},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 1.0}
      },
      %{
        "index" => 1,
        "absolute_index" => 1,
        "dsex_passed" => false,
        "dspy_passed" => true,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "dsex_answer" => "Both are magazines.",
        "dspy_answer" => "yes",
        "dsex_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "dsex_metric_metadata" => %{"official_hotpotqa_f1" => 0.0},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 1.0}
      },
      %{
        "index" => 2,
        "absolute_index" => 2,
        "dsex_passed" => true,
        "dspy_passed" => false,
        "pass_agreement" => false,
        "answer_agreement" => false,
        "dsex_answer" => "Paris France",
        "dspy_answer" => "Paris",
        "dsex_duration_ms" => 20.0,
        "dspy_duration_ms" => 10.0,
        "dsex_metric_metadata" => %{"official_hotpotqa_f1" => 1.0},
        "dspy_metric_metadata" => %{"official_hotpotqa_f1" => 0.5}
      }
    ]

    report = %{
      "schema_version" => 1,
      "generated_at" => "2026-07-06T00:00:00Z",
      "campaign_id" => "analysis-run",
      "dsex" => %{"model" => %{"provider" => "req_llm", "model" => "gpt-test"}},
      "dspy" => %{"model" => %{"model" => "openai/gpt-test"}},
      "generation" => %{"temperature" => 0.0, "max_tokens" => 700},
      "tasks" => [
        %{
          "task" => "hotpotqa",
          "offset" => 0,
          "examples" => length(rows),
          "dsex_duration_ms" => 10.0,
          "dspy_duration_ms" => 20.0,
          "row_agreement" => rows
        }
      ],
      "evidence" => %{"examples" => length(rows)}
    }

    File.write!(Path.join(out_dir, name), Jason.encode!(report, pretty: true) <> "\n")
  end

  defp write_campaign_artifact(out_dir, name, artifact) do
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
        "dsex_recorded_count" => 1,
        "dspy_recorded_count" => 1,
        "dsex_distinct" => [%{"temperature" => 0.0, "max_tokens" => 700}],
        "dspy_distinct" => [%{"temperature" => 0.0, "max_tokens" => 700}],
        "wire_api_complete" => true,
        "wire_api_matched" => true,
        "dsex_wire_api_recorded_count" => 1,
        "dspy_wire_api_recorded_count" => 1,
        "dsex_wire_api_distinct" => ["openai_chat_completions"],
        "dspy_wire_api_distinct" => ["openai_chat_completions"]
      }
    }
  end

  defp current_prompt_contract do
    DSEx.BenchmarkTruth.Contract.current_prompt_contract()
  end

  defp instrumented_task_pair(rows_per_task) do
    Enum.map(["gsm8k", "hotpotqa"], fn task ->
      %{
        "task" => task,
        "dsex_errors" => [],
        "dspy_errors" => [],
        "dsex_instrumentation" => %{
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
          "message_chars_ratio_dsex_over_dspy_mean" => 1.02,
          "raw_chars_ratio_dsex_over_dspy_mean" => 0.22
        }
      }
    end)
  end
end
