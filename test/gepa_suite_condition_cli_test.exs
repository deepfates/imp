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

      assert receipt["treatments"]["gepa_v0_1_4_no_merge"]["execution_profile"] ==
               "gepa_v0_1_4"
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
          "gepa_v0_1_4_no_merge",
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
        Path.join(System.tmp_dir!(), "imp-gepa-must-not-exist.json"),
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
    assert output =~ "owner cap before transport"
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

  defp sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
