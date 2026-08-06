defmodule Imp.GepaSuiteConditionCLITest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  test "ordinary Imp entrance prepares all six treatments without providers or heldout decode" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")

    common = [
      "run",
      "--no-start",
      script,
      "--dataset-root",
      Path.join(root, "tmp/gepa-six-task-current-root"),
      "--retrieval-root",
      Path.join(root, "tmp/hover-materialization-v1/retrieval/semantic-probe-root"),
      "--retrieval-receipt",
      Path.join(root, "tmp/hover-materialization-v1/materialization.json"),
      "--retrieval-python",
      Path.join(root, "tmp/dspy-parity-venv/bin/python"),
      "--arm",
      "baseline"
    ]

    for family <- Imp.BenchmarkTruth.GepaSuite.families() do
      {output, 0} =
        System.cmd("mix", common ++ ["--family", family],
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert receipt["family"] == family
      assert receipt["status"] == "provider_disabled_ready"
      assert receipt["heldout_decoded"] == false
      assert receipt["provider_calls_authorized"] == false
      assert receipt["outer_max_concurrency"] == 1
      assert receipt["request_timeout_ms"] == 120_000

      assert receipt["req_llm_pool"] == %{
               "protocols" => ["http1"],
               "size" => 1,
               "count" => 1
             }

      assert receipt["treatments"]["mipro_v2_heavy"]["auto"] == "heavy"

      assert receipt["treatments"]["gepa_v0_1_4_merge"]["execution_profile"] ==
               "gepa_v0_1_4_merge"
    end
  end

  test "fresh entrance applies a schema-3 Artifact and serves four calls through ProgramServer" do
    root = File.cwd!()

    output_root =
      Path.join(System.tmp_dir!(), "imp-gepa-cli-#{System.unique_integer([:positive])}")

    artifact_path = Path.join(output_root, "selected.artifact.json")
    fresh_path = Path.join(output_root, "fresh.json")
    on_exit(fn -> File.rm_rf!(output_root) end)

    lm = Imp.LM.Static.new()

    prepared =
      Imp.BenchmarkTruth.GepaStudyCondition.prepare!(
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "AIMEBench",
        %{task: lm, reflection: lm, judge: lm}
      )

    candidate =
      Imp.Optimizer.Artifact.parameter_candidate("fixture", prepared.program, score: 0.0)

    candidate
    |> Imp.Optimizer.Artifact.new([], provenance: %{kind: :provider_disabled_fixture})
    |> Imp.Optimizer.Artifact.write!(artifact_path)

    {output, 0} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          Path.join(root, "scripts/gepa_suite_condition.exs"),
          "--fresh",
          "--provider-disabled-fixture",
          "--dataset-root",
          Path.join(root, "tmp/gepa-six-task-current-root"),
          "--family",
          "AIMEBench",
          "--arm",
          "gepa_v0_1_4_merge",
          "--artifact",
          artifact_path,
          "--fresh-output",
          fresh_path
        ],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output == ""
    receipt = fresh_path |> File.read!() |> Jason.decode!()
    assert receipt["status"] == "fresh_ok"
    assert receipt["usage_cost_basis"] == "frozen_catalog_calculated"
    assert length(receipt["calls"]) == 4
    assert Enum.all?(receipt["calls"], &(&1["status"] == "ok"))

    assert receipt["usage"] == %{
             "events" => [],
             "summary" => %{
               "cost_usd" => 0.0,
               "input_tokens" => 0,
               "output_tokens" => 0,
               "request_duration_us" => 0,
               "request_attempts" => 0,
               "request_starts" => 0,
               "json_fallbacks" => 0,
               "usage_events" => 0
             }
           }

    progress_path = fresh_path <> ".progress.jsonl"
    assert receipt["progress_sha256"] == sha256(progress_path)
    assert File.stat!(progress_path).mode |> Bitwise.band(0o777) == 0o600
    assert [header] = progress_path |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(header)["event"] == "start"
    assert is_integer(receipt["wall_time_us"])
    assert receipt["wall_time_us"] >= 0
  end

  test "live entrance refuses an over-cap condition before transport" do
    root = File.cwd!()

    output_root =
      Path.join(System.tmp_dir!(), "imp-gepa-cap-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output_root)
    File.chmod!(output_root, 0o700)
    on_exit(fn -> File.rm_rf!(output_root) end)

    args =
      [
        "run",
        "--no-start",
        Path.join(root, "scripts/gepa_suite_condition.exs"),
        "--run",
        "--dataset-root",
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "--family",
        "AIMEBench",
        "--arm",
        "baseline",
        "--output",
        Path.join(output_root, "result.json"),
        "--input-price-per-million",
        "0.14",
        "--output-price-per-million",
        "0.28",
        "--initial-cost-usd",
        "0.0",
        "--max-cost-usd",
        "0.000001"
      ] ++
        Enum.flat_map(["task", "reflection", "judge"], fn role ->
          [
            "--#{role}-model",
            "provider-disabled/model",
            "--#{role}-provider",
            "provider/endpoint",
            "--#{role}-max-input-bytes",
            "2",
            "--#{role}-max-output-tokens",
            "16"
          ]
        end)

    {output, status} =
      System.cmd("mix", args,
        env: [{"MIX_ENV", "test"}, {"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "next task transport would exceed the owner cap"
    receipt = output_root |> Path.join("result.json") |> File.read!() |> Jason.decode!()
    assert receipt["status"] == "failed"
    assert receipt["usage"]["summary"]["request_starts"] == 0
  end

  test "LiveBench live entrance authenticates the symbolic scorer before transport" do
    root = File.cwd!()

    output_root =
      Path.join(System.tmp_dir!(), "imp-livebench-cap-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output_root)
    File.chmod!(output_root, 0o700)
    on_exit(fn -> File.rm_rf!(output_root) end)
    output_path = Path.join(output_root, "result.json")
    File.rm(output_path)

    args =
      [
        "run",
        "--no-start",
        Path.join(root, "scripts/gepa_suite_condition.exs"),
        "--run",
        "--dataset-root",
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "--family",
        "LiveBenchMathBench",
        "--arm",
        "baseline",
        "--output",
        output_path,
        "--livebench-math-python",
        "/usr/bin/false",
        "--input-price-per-million",
        "0.14",
        "--output-price-per-million",
        "0.28",
        "--initial-cost-usd",
        "0.0",
        "--max-cost-usd",
        "20.0"
      ] ++
        Enum.flat_map(["task", "reflection", "judge"], fn role ->
          [
            "--#{role}-model",
            "provider-disabled/model",
            "--#{role}-provider",
            "provider/endpoint",
            "--#{role}-max-input-bytes",
            "65536",
            "--#{role}-max-output-tokens",
            "4096"
          ]
        end)

    {output, status} =
      System.cmd("mix", args,
        env: [{"MIX_ENV", "test"}, {"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "symbolic scorer preflight failed"
    refute File.exists?(output_path)

    admitted =
      List.replace_at(
        args,
        Enum.find_index(args, &(&1 == "/usr/bin/false")),
        Path.join(root, "tmp/dspy-parity-venv/bin/python")
      )
      |> then(fn values ->
        index = Enum.find_index(values, &(&1 == "20.0"))
        List.replace_at(values, index, "0.000001")
      end)

    {output, status} =
      System.cmd("mix", admitted,
        env: [{"MIX_ENV", "test"}, {"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "next task transport would exceed the owner cap"
    refute output =~ "symbolic scorer preflight"
    receipt = output_path |> File.read!() |> Jason.decode!()
    assert receipt["status"] == "failed"
    assert receipt["usage"]["summary"]["request_starts"] == 0
  end

  test "runtime observer persists nested usage and adapter fallback progress" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")
    source = File.read!(script)

    body =
      String.replace_suffix(
        source,
        "Imp.GepaSuiteConditionCLI.main(System.argv())\n",
        ""
      )

    Code.compile_string(body, script)

    output_root =
      Path.join(System.tmp_dir!(), "imp-gepa-observer-#{System.unique_integer([:positive])}")

    progress_path = Path.join(output_root, "progress.jsonl")
    File.mkdir_p!(output_root)
    File.write!(progress_path, "")
    on_exit(fn -> File.rm_rf!(output_root) end)

    {:ok, usage} =
      Agent.start_link(fn ->
        %{
          "summary" => %{
            "usage_events" => 0,
            "request_attempts" => 0,
            "request_starts" => 0,
            "json_fallbacks" => 0,
            "request_duration_us" => 0,
            "input_tokens" => 0,
            "output_tokens" => 0,
            "cost_usd" => 0.0
          },
          "events" => [],
          "progress_path" => progress_path,
          "next_sequence" => 1
        }
      end)

    apply(Imp.GepaSuiteConditionCLI, :handle_runtime_event, [
      [:req_llm, :request, :start],
      %{system_time: 1},
      %{request_id: "request-1", provider: :openrouter, model: %{id: "model"}},
      usage
    ])

    apply(Imp.GepaSuiteConditionCLI, :handle_runtime_event, [
      [:req_llm, :request, :stop],
      %{duration: 1_000},
      %{
        usage: %{tokens: %{input: 7, output: 3}, total_cost: 0.001},
        request_id: "request-1"
      },
      usage
    ])

    apply(Imp.GepaSuiteConditionCLI, :handle_runtime_event, [
      [:imp, :adapter, :parse, :json_fallback],
      %{count: 1},
      %{adapter: Imp.Adapter.Chat, error: "strict marker parse failed"},
      usage
    ])

    state = Agent.get(usage, & &1)
    Agent.stop(usage)

    assert state["summary"]["request_attempts"] == 1
    assert state["summary"]["request_starts"] == 1
    assert state["summary"]["usage_events"] == 1
    assert state["summary"]["json_fallbacks"] == 1
    assert state["summary"]["input_tokens"] == 7
    assert state["summary"]["output_tokens"] == 3
    assert state["summary"]["cost_usd"] == 0.001

    assert progress_path |> File.read!() |> String.split("\n", trim: true) |> length() == 3
  end

  test "cross-runtime input identity normalizes JSON control escape spelling" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")
    source = File.read!(script)

    body =
      String.replace_suffix(
        source,
        "Imp.GepaSuiteConditionCLI.main(System.argv())\n",
        ""
      )

    Code.compile_string(body, script)

    value = %{
      "joined" => "literal backslash\\\vtab",
      "prompt" => "literal \\u000B text and vertical\vtab",
      "row" => 82
    }

    # hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
    # ensure_ascii=False).encode()).hexdigest()
    assert apply(Imp.GepaSuiteConditionCLI, :canonical_sha256, [value]) ==
             "16d8efd5b0233ede64694cc890229b856c13155497ba5ce8c9f6ee173a8c8ad1"
  end

  test "live model prices produce catalog-calculated request costs" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")
    source = File.read!(script)

    body =
      String.replace_suffix(
        source,
        "Imp.GepaSuiteConditionCLI.main(System.argv())\n",
        ""
      )

    Code.compile_string(body, script)

    spec =
      apply(Imp.GepaSuiteConditionCLI, :priced_model_spec, [
        "provider-disabled/model",
        0.14,
        0.28
      ])

    assert {:ok, model} = ReqLLM.model(spec)

    assert {:ok, %{total_cost: 0.000002}} =
             ReqLLM.Usage.Cost.breakdown(
               %{input_tokens: 10, output_tokens: 3, total_tokens: 13},
               model
             )
  end

  test "prospective guard admits useful work, reconciles actual cost, and stops the next request" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")
    source = File.read!(script)

    body =
      String.replace_suffix(
        source,
        "Imp.GepaSuiteConditionCLI.main(System.argv())\n",
        ""
      )

    Code.compile_string(body, script)
    guard = apply(Imp.GepaSuiteSpendGuard, :start_link!, [0.5, 1.0])

    inner =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            __imp_lm_output__: %{answer: "ok"},
            __imp_lm_metadata__: %{
              req_llm: %{usage: %{input_tokens: 1, output_tokens: 1, total_cost: 0.1}}
            }
          }
        end
      )

    lm = apply(Imp.GepaSuiteSpendGuard, :wrap, [inner, guard, :task, 0.4, 1.0, 1.0])
    assert {:ok, _} = Imp.LM.generate(lm, [%{role: :user, content: "one"}])
    assert {:ok, _} = Imp.LM.generate(lm, [%{role: :user, content: "two"}])

    assert {:error, %Imp.OperationalSafetyError{kind: :budget}} =
             Imp.LM.generate(lm, [%{role: :user, content: "three"}])

    assert %{
             initial_actual_cost_usd: 0.5,
             reconciled_accounted_cost_usd: reconciled,
             accounted_total_usd: accounted,
             active_requests: 0
           } = apply(Imp.GepaSuiteSpendGuard, :snapshot, [guard])

    assert_in_delta reconciled, 0.2, 1.0e-12
    assert_in_delta accounted, 0.7, 1.0e-12
    Agent.stop(guard)

    zero_reported =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            __imp_lm_output__: %{answer: "ok"},
            __imp_lm_metadata__: %{
              req_llm: %{usage: %{input_tokens: 100, output_tokens: 100, total_cost: 0.0}}
            }
          }
        end
      )

    guard = apply(Imp.GepaSuiteSpendGuard, :start_link!, [0.0, 1.0])

    lm =
      apply(Imp.GepaSuiteSpendGuard, :wrap, [
        zero_reported,
        guard,
        :task,
        0.5,
        1_000.0,
        2_000.0
      ])

    assert {:ok, _} = Imp.LM.generate(lm, [%{role: :user, content: "priced"}])

    assert %{reconciled_accounted_cost_usd: zero_accounted} =
             apply(Imp.GepaSuiteSpendGuard, :snapshot, [guard])

    assert_in_delta zero_accounted, 0.3, 1.0e-12

    Agent.stop(guard)
  end

  test "prospective guard atomically accounts for concurrent reservations" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition.exs")
    source = File.read!(script)

    body =
      String.replace_suffix(
        source,
        "Imp.GepaSuiteConditionCLI.main(System.argv())\n",
        ""
      )

    Code.compile_string(body, script)
    guard = apply(Imp.GepaSuiteSpendGuard, :start_link!, [0.0, 0.5])
    parent = self()

    inner =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(parent, {:reserved, self()})

          receive do
            :continue -> :ok
          end

          %{
            __imp_lm_output__: %{answer: "ok"},
            __imp_lm_metadata__: %{
              req_llm: %{usage: %{input_tokens: 1, output_tokens: 1, total_cost: 0.1}}
            }
          }
        end
      )

    lm = apply(Imp.GepaSuiteSpendGuard, :wrap, [inner, guard, :task, 0.4, 1.0, 1.0])
    first = Task.async(fn -> Imp.LM.generate(lm, [%{role: :user, content: "one"}]) end)
    assert_receive {:reserved, first_pid}

    assert {:error, %Imp.OperationalSafetyError{kind: :budget}} =
             Imp.LM.generate(lm, [%{role: :user, content: "two"}])

    send(first_pid, :continue)
    assert {:ok, _} = Task.await(first)

    assert %{active_requests: 0, accounted_total_usd: 0.1} =
             apply(Imp.GepaSuiteSpendGuard, :snapshot, [guard])

    Agent.stop(guard)
  end

  defp sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
