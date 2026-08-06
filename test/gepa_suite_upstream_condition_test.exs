defmodule Imp.BenchmarkTruth.GepaSuiteUpstreamConditionTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  test "pinned DSPy entrance prepares every official family without decoding heldout" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")

    common = [
      "-P",
      script,
      "--dspy-root",
      Path.join(root, "tmp/dspy-3.2.1"),
      "--gepa-root",
      Path.join(root, "tmp/gepa-v0.1.4"),
      "--artifact-root",
      Path.join(root, "tmp/gepa-artifact"),
      "--dataset-root",
      Path.join(root, "tmp/gepa-six-task-current-root"),
      "--retrieval-root",
      Path.join(root, "tmp/hover-materialization-v1/retrieval/semantic-probe-root"),
      "--retrieval-receipt",
      Path.join(root, "tmp/hover-materialization-v1/materialization.json"),
      "--arm",
      "baseline",
      "--max-concurrency",
      "8"
    ]

    for family <- Imp.BenchmarkTruth.GepaSuite.families() do
      {output, 0} = System.cmd(python, common ++ ["--family", family], stderr_to_stdout: true)
      receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert receipt["family"] == family
      assert receipt["status"] == "provider_disabled_ready"
      assert receipt["heldout_decoded"] == false
      assert receipt["outer_max_concurrency"] == 8
      assert receipt["condition"]["seed"] == 2_026_080_101
      assert receipt["data"]["split_counts"] == receipt["splits"]
      assert map_size(receipt["data"]["split_checksums"]) == 3

      assert receipt["condition"]["source_commit"] ==
               String.trim(git!(root, ["rev-parse", "HEAD"]))

      assert receipt["condition"]["route"] == %{
               "api_base" => "https://openrouter.ai/api/v1",
               "data_collection" => "deny",
               "require_parameters" => true,
               "response_cache" => false,
               "usage_required" => true,
               "zdr" => true
             }

      expected_judge_treatment =
        if family == "Papillon",
          do:
            "source_scoring_procedure_with_matched_current_model_judge_not_historical_judge_reproduction",
          else: "not_applicable"

      assert receipt["condition"]["papillon_judge_treatment"] == expected_judge_treatment

      assert receipt["treatments"] == %{
               "mipro_v2_heavy" => %{"max_concurrency" => 8},
               "gepa_v0_1_4_merge" => %{"max_concurrency" => 8}
             }
    end
  end

  test "pinned DSPy live entrance refuses to overwrite retained evidence before transport" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")

    output_root =
      Path.join(System.tmp_dir!(), "dspy-gepa-overwrite-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output_root)
    output = Path.join(output_root, "result.json")
    File.write!(output, "retained\n")
    on_exit(fn -> File.rm_rf!(output_root) end)

    args =
      [
        "-P",
        Path.join(root, "scripts/gepa_suite_condition_upstream.py"),
        "--run",
        "--dspy-root",
        Path.join(root, "tmp/dspy-3.2.1"),
        "--gepa-root",
        Path.join(root, "tmp/gepa-v0.1.4"),
        "--artifact-root",
        Path.join(root, "tmp/gepa-artifact"),
        "--dataset-root",
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "--family",
        "AIMEBench",
        "--arm",
        "baseline",
        "--output",
        output,
        "--input-price-per-million",
        "0.14",
        "--output-price-per-million",
        "0.28",
        "--initial-cost-usd",
        "0.0",
        "--max-cost-usd",
        "1.0"
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

    {message, status} =
      System.cmd(python, args,
        env: [{"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert message =~ "refusing to overwrite existing evidence"
    assert File.read!(output) == "retained\n"
    refute File.exists?(output <> ".progress.jsonl")
  end

  test "pinned DSPy progress creation is an atomic non-overwrite admission lock" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")

    probe = ~S'''
    import argparse, importlib.util, pathlib, sys, tempfile
    path = pathlib.Path(sys.argv[1])
    spec = importlib.util.spec_from_file_location("condition", path)
    condition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(condition)
    root = pathlib.Path(tempfile.mkdtemp())
    output = root / "result.json"
    progress = output.with_suffix(".json.progress.jsonl")
    progress.write_text("retained-evidence\n")
    args = argparse.Namespace(output=output, family="AIMEBench", arm="baseline", seed=2026080101, max_concurrency=1)
    try:
        condition.init_progress(args)
    except FileExistsError:
        pass
    else:
        raise AssertionError("existing progress evidence was overwritten")
    assert progress.read_text() == "retained-evidence\n"
    '''

    assert {"", 0} = System.cmd(python, ["-P", "-c", probe, script], stderr_to_stdout: true)
  end

  test "pinned DSPy atomically publishes receipts and reauthenticates heldout decode bytes" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")

    probe = ~S'''
    import hashlib, importlib.util, json, pathlib, sys, tempfile
    path = pathlib.Path(sys.argv[1])
    spec = importlib.util.spec_from_file_location("condition", path)
    condition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(condition)
    root = pathlib.Path(tempfile.mkdtemp())
    receipt = root / "result.json"
    condition.write_private_json(receipt, {"status": "complete"})
    assert json.loads(receipt.read_text()) == {"status": "complete"}
    try:
        condition.write_private_json(receipt, {"status": "replacement"})
    except RuntimeError as error:
        assert "refusing to overwrite" in str(error)
    else:
        raise AssertionError("receipt was replaced")
    assert json.loads(receipt.read_text()) == {"status": "complete"}

    heldout = root / "test.jsonl"
    original = b'{"problem":"test","answer":"3"}\n'
    heldout.write_bytes(original)
    family = {
        "family": "AIMEBench",
        "input_keys": ["problem"],
        "split_counts": {"test": 1},
        "split_checksums": {"test": "sha256:" + hashlib.sha256(original).hexdigest()},
    }
    class Example:
        def __init__(self, **values): self.values = values
        def with_inputs(self, *keys): return self
    class DSPy: pass
    DSPy.Example = Example
    assert len(condition.load_verified_rows(DSPy, heldout, family, "test")) == 1
    heldout.write_text('{"problem":"replacement","answer":"3"}\n')
    try:
        condition.load_verified_rows(DSPy, heldout, family, "test")
    except RuntimeError as error:
        assert "digest drift at decode barrier" in str(error)
    else:
        raise AssertionError("same-count heldout replacement was accepted")
    '''

    assert {"", 0} = System.cmd(python, ["-P", "-c", probe, script], stderr_to_stdout: true)
  end

  test "pinned DSPy selected state cannot replace an existing target" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")

    probe = ~S'''
    import importlib.util, pathlib, sys, tempfile
    path = pathlib.Path(sys.argv[1])
    spec = importlib.util.spec_from_file_location("condition", path)
    condition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(condition)
    root = pathlib.Path(tempfile.mkdtemp())
    target = root / "selected.json"
    class Program:
        def __init__(self, value): self.value = value
        def save(self, path, save_program=False):
            assert save_program is False
            pathlib.Path(path).write_text(self.value)
    condition.save_state_exclusive(Program("first"), target)
    try:
        condition.save_state_exclusive(Program("second"), target)
    except FileExistsError:
        pass
    else:
        raise AssertionError("existing selected state was replaced")
    assert target.read_text() == "first"
    '''

    assert {"", 0} = System.cmd(python, ["-P", "-c", probe, script], stderr_to_stdout: true)
  end

  test "upstream entrance enforces the same nested content-byte envelope before transport" do
    root = File.cwd!()
    script = Path.join(root, "scripts/gepa_suite_condition_upstream.py")
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")

    probe = """
    import argparse, asyncio, importlib.util, json, pathlib, sys, tempfile
    path = pathlib.Path(sys.argv[1])
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location("condition", path)
    condition = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(condition)

    class FakeLM:
        def __init__(self, **kwargs): self.kwargs = kwargs
        def forward(self, prompt=None, messages=None, **kwargs):
            return {"id":"id", "model":"model", "choices":[{"finish_reason":"stop"}],
                    "usage":{"prompt_tokens":1,"completion_tokens":1,"cost":0.0}}
        async def aforward(self, prompt=None, messages=None, **kwargs): return self.forward(prompt, messages, **kwargs)
    dspy = type("DSPy", (), {"LM": FakeLM})
    args = argparse.Namespace(
        task_model="model", task_provider="provider", task_max_input_bytes=2,
        task_max_output_tokens=16, input_price_per_million=0.14,
        output_price_per_million=0.28, api_base="https://example.invalid", api_key_env="TEST_KEY",
        task_input_price_per_million=0.09, task_output_price_per_million=0.18,
        family="AIMEBench", arm="baseline", seed=17, max_concurrency=8,
        initial_cost_usd=0.0, max_cost_usd=1.0
    )
    tmp = tempfile.TemporaryDirectory()
    args.output = pathlib.Path(tmp.name) / "result.json"
    progress = condition.init_progress(args)
    condition.SPEND_GUARD = condition.ProspectiveSpendGuard(0.0, 1.0)
    lm = condition.make_lm(dspy, "task", args)
    assert lm.kwargs["extra_body"]["provider"]["max_price"] == {
        "prompt": 0.09, "completion": 0.18
    }
    baseline = object()
    selected = object()
    assert condition.arm_program("baseline", baseline, selected) is baseline
    assert condition.arm_program("mipro_v2_heavy", baseline, selected) is selected
    assert condition.arm_requires_fresh_state("baseline") is False
    assert condition.arm_requires_fresh_state("gepa_v0_1_4_merge") is True
    assert lm.forward(messages=[{"role": "user", "content": "é"}])["id"] == "id"
    usage = condition.runtime_usage()["summary"]["task"]
    assert usage["request_attempts"] == 1
    assert usage["usage_events"] == 1
    assert usage["input_tokens"] == 1
    assert usage["output_tokens"] == 1
    assert usage["cost_usd"] == 0.0
    assert condition.SPEND_GUARD.snapshot()["reconciled_accounted_cost_usd"] > 0
    progress_lines = progress.read_text().splitlines()
    assert len(progress_lines) == 2
    assert progress.stat().st_mode & 0o777 == 0o600
    assert json.loads(progress_lines[1])["sequence"] == 1
    args.judge_max_input_bytes = 2
    args.judge_max_output_tokens = 16
    admission = condition.spend_admission(args)
    assert admission["owner_cap_usd"] == 1.0
    active_guard = condition.ProspectiveSpendGuard(0.0, 0.5)
    active_id = active_guard.reserve("task", 0.4)
    try:
        active_guard.reserve("task", 0.4)
    except condition.OperationalSafetyAbort:
        pass
    else:
        raise AssertionError("active reservations oversubscribed the owner cap")
    active_guard.settle(active_id, 0.1)
    assert active_guard.snapshot()["accounted_total_usd"] == 0.1
    condition.SPEND_GUARD = condition.ProspectiveSpendGuard(0.0, 0.000001)
    try:
        lm.forward(messages=[{"role": "user", "content": "a"}])
    except condition.OperationalSafetyAbort as error:
        assert "next task transport would exceed the owner cap" in str(error)
    else:
        raise AssertionError("over-cap next transport was admitted")
    condition.SPEND_GUARD = condition.ProspectiveSpendGuard(0.0, 1.0)
    try:
        lm.forward(messages=[{"role": "user", "content": "abc"}])
    except condition.OperationalSafetyAbort as error:
        assert "before transport" in str(error)
    else:
        raise AssertionError("oversized input reached transport")
    try:
        asyncio.run(lm.aforward(messages=[{"role": "user", "content": "abc"}]))
    except condition.OperationalSafetyAbort as error:
        assert "before transport" in str(error)
    else:
        raise AssertionError("oversized async input reached transport")
    """

    {output, 0} =
      System.cmd(python, ["-c", probe, script],
        env: [{"TEST_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert output == ""
  end

  test "LiveBench upstream entrance authenticates the shared symbolic scorer before transport" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")

    output_root =
      Path.join(System.tmp_dir!(), "dspy-livebench-scorer-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output_root)
    File.chmod!(output_root, 0o700)
    output = Path.join(output_root, "result.json")
    on_exit(fn -> File.rm_rf!(output_root) end)

    common =
      [
        "-P",
        Path.join(root, "scripts/gepa_suite_condition_upstream.py"),
        "--run",
        "--dspy-root",
        Path.join(root, "tmp/dspy-3.2.1"),
        "--gepa-root",
        Path.join(root, "tmp/gepa-v0.1.4"),
        "--artifact-root",
        Path.join(root, "tmp/gepa-artifact"),
        "--dataset-root",
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "--family",
        "LiveBenchMathBench",
        "--arm",
        "baseline",
        "--output",
        output,
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

    {missing_output, missing_status} =
      System.cmd(python, common,
        env: [{"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert missing_status != 0
    assert missing_output =~ "requires --livebench-math-python"

    assert %{"stage" => "preflight", "status" => "failed"} =
             output |> File.read!() |> Jason.decode!()

    File.rm!(output)

    admitted =
      common ++
        [
          "--livebench-math-python",
          python,
          "--max-cost-usd",
          "0.000001"
        ]

    {admitted_output, admitted_status} =
      System.cmd(python, admitted,
        env: [{"OPENROUTER_API_KEY", "not-a-provider-key"}],
        stderr_to_stdout: true
      )

    assert admitted_status != 0
    assert admitted_output =~ "next task transport would exceed the owner cap"
    refute admitted_output =~ "symbolic scorer preflight"

    assert %{"stage" => "heldout", "status" => "failed"} =
             output |> File.read!() |> Jason.decode!()
  end

  test "portable LiveBench AMPS bridge matches pinned scorer semantics on every frozen row" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")

    probe = ~S'''
    import importlib, json, pathlib, sys
    root = pathlib.Path(sys.argv[1])
    sys.path.insert(0, str(root / "tmp/gepa-artifact"))
    sys.path.insert(0, str(root / "scripts"))
    official = importlib.import_module(
        "gepa_artifact.benchmarks.livebench_math.livebenchmath_utils.AMPS_Hard.utils"
    )
    bridge = importlib.import_module("livebench_math_score")
    official.run_with_timeout = lambda func, args=(), timeout=8: func(*args)
    rows = [
        json.loads(line)
        for line in (root / "tmp/gepa-six-task-current-root/LiveBenchMathBench/test.jsonl").read_text().splitlines()
        if line.strip()
    ]
    compared = 0
    for row in rows:
        question = row["question_d"]
        if question["task"] != "AMPS_Hard":
            continue
        gold = str(question["ground_truth"])
        for answer in (rf"\boxed{{{gold}}}", "not a symbolic answer"):
            expected = official.amps_hard_process_results(gold, answer)[0]
            actual = bridge.amps_hard_process_results(gold, answer)[0]
            assert actual == expected, (question["question_id"], answer, expected, actual)
            compared += 1
    assert compared == 104
    print(json.dumps({"rows": compared // 2, "predictions": compared}))
    '''

    {output, 0} = System.cmd(python, ["-P", "-c", probe, root], stderr_to_stdout: true)
    receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert receipt == %{"predictions" => 104, "rows" => 52}
  end

  test "AIME primary and Chat-to-JSON fallback messages match pinned DSPy exactly" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-parity-venv/bin/python")

    for {path, commit} <- [
          {"tmp/dspy-3.2.1", "29448ae12756abdd14bd8796c819247ebb83673c"},
          {"tmp/gepa-v0.1.4", "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"},
          {"tmp/gepa-artifact", "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"}
        ] do
      source = Path.join(root, path)
      assert {head, 0} = System.cmd("git", ["-C", source, "rev-parse", "HEAD"])
      assert String.trim(head) == commit
      assert {"", 0} = System.cmd("git", ["-C", source, "diff", "--quiet"])
      assert {"", 0} = System.cmd("git", ["-C", source, "diff", "--cached", "--quiet"])
    end

    probe = ~S'''
    import copy, importlib, json, pathlib, sys
    root = pathlib.Path(sys.argv[1])
    sys.path.insert(0, str(root / "scripts"))
    from dspy_gepa_version_bridge import install_source_bridge
    install_source_bridge(root / "tmp/dspy-3.2.1", root / "tmp/gepa-v0.1.4")
    import dspy
    sys.path.insert(0, str(root / "tmp/gepa-artifact"))
    from dspy.dsp.utils.utils import dotdict

    program = copy.deepcopy(
        importlib.import_module("gepa_artifact.benchmarks.AIME").benchmark[0].program[0]
    )

    class CaptureLM(dspy.BaseLM):
        def __init__(self):
            super().__init__("provider-disabled-aime", cache=False)
            self.calls = []
            self.responses = ["truncated", '{"reasoning":"x","answer":"0"}']

        def copy(self, **kwargs):
            self.kwargs = {**self.kwargs, **kwargs}
            return self

        def __deepcopy__(self, _memo):
            return self

        def forward(self, prompt=None, messages=None, **_kwargs):
            self.calls.append(messages or [{"role": "user", "content": prompt}])
            content = self.responses.pop(0)
            return dotdict(
                choices=[dotdict(
                    message=dotdict(content=content, tool_calls=None),
                    finish_reason="stop",
                )],
                usage=dotdict(prompt_tokens=0, completion_tokens=0, total_tokens=0),
                model="provider-disabled-aime",
            )

    lm = CaptureLM()
    program.set_lm(lm)
    with (root / "tmp/gepa-six-task-current-root/AIMEBench/test.jsonl").open() as handle:
        row = json.loads(next(handle))
    with dspy.context(lm=lm):
        program(problem=row["problem"])
    print(json.dumps(lm.calls, sort_keys=True, separators=(",", ":")))
    '''

    {upstream_json, 0} = System.cmd(python, ["-P", "-c", probe, root])
    upstream = Jason.decode!(upstream_json)
    parent = self()

    {:ok, responses} =
      Agent.start_link(fn -> ["truncated", ~s({"reasoning":"x","answer":"0"})] end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:aime_messages, messages})
          Agent.get_and_update(responses, fn [response | rest] -> {response, rest} end)
        end
      )

    prepared =
      Imp.BenchmarkTruth.GepaStudyCondition.prepare!(
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "AIMEBench",
        %{task: lm, reflection: lm, judge: lm}
      )

    [row | _] = Imp.BenchmarkTruth.GepaSuite.load_test!(prepared.loaded)
    problem = Imp.Example.fetch!(row, :problem)

    assert {:ok, _prediction} =
             Imp.Module.call(prepared.program, %{"problem" => problem})

    actual =
      for _ <- 1..2 do
        assert_receive {:aime_messages, messages}

        Enum.map(messages, fn message ->
          %{"role" => to_string(message.role), "content" => message.content}
        end)
      end

    assert actual == upstream
  end

  test "AIME live-route request bodies differ only by explicit protocol defaults" do
    root = File.cwd!()
    parent = self()
    model = "deepseek/deepseek-v4-flash-0731"
    provider = "novita/fp8"

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        send(parent, {:aime_wire, Jason.decode!(request.body), request.headers})

        {200,
         %{
           "id" => "provider-disabled-aime",
           "object" => "chat.completion",
           "model" => model,
           "choices" => [
             %{
               "index" => 0,
               "message" => %{
                 "role" => "assistant",
                 "content" =>
                   "[[ ## reasoning ## ]]\nx\n\n[[ ## answer ## ]]\n0\n\n[[ ## completed ## ]]"
               },
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{
             "prompt_tokens" => 1,
             "completion_tokens" => 1,
             "total_tokens" => 2,
             "cost" => 0.0
           }
         }}
      end)

    lm =
      Imp.req_llm(
        %{
          provider: :openrouter,
          id: model,
          model: model,
          base_url: base_url <> "/v1",
          cost: %{input: 0.14, output: 0.28}
        },
        api_key: "provider-disabled",
        cache: false,
        temperature: 1.0,
        max_tokens: 4096,
        timeout: 120_000,
        max_retries: 0,
        input_envelope: [max_bytes: 65_536, reservation_tokens: 65_536],
        provider_options: [
          openrouter_provider: %{
            only: [provider],
            order: [provider],
            allow_fallbacks: false,
            require_parameters: true,
            data_collection: "deny",
            zdr: true,
            max_price: %{prompt: 0.14, completion: 0.28}
          },
          openrouter_usage: %{include: true}
        ],
        req_http_options: [
          headers: [
            {"X-OpenRouter-Metadata", "enabled"},
            {"X-OpenRouter-Cache", "false"}
          ],
          retry: false,
          max_retries: 0
        ]
      )

    prepared =
      Imp.BenchmarkTruth.GepaStudyCondition.prepare!(
        Path.join(root, "tmp/gepa-six-task-current-root"),
        "AIMEBench",
        %{task: lm, reflection: lm, judge: lm}
      )

    [row | _] = Imp.BenchmarkTruth.GepaSuite.load_test!(prepared.loaded)
    problem = Imp.Example.fetch!(row, :problem)
    assert {:ok, _} = Imp.Module.call(prepared.program, %{"problem" => problem})
    assert_receive {:aime_wire, imp_body, imp_headers}

    probe = ~S'''
    import copy, importlib, json, pathlib, sys
    root, base_url, model, provider = sys.argv[1:]
    root = pathlib.Path(root)
    sys.path.insert(0, str(root / "scripts"))
    from dspy_gepa_version_bridge import install_source_bridge
    install_source_bridge(root / "tmp/dspy-3.2.1", root / "tmp/gepa-v0.1.4")
    import dspy
    sys.path.insert(0, str(root / "tmp/gepa-artifact"))
    program = copy.deepcopy(importlib.import_module("gepa_artifact.benchmarks.AIME").benchmark[0].program[0])
    lm = dspy.LM(
        model="openrouter/" + model,
        api_base=base_url + "/v1",
        api_key="provider-disabled",
        temperature=1.0,
        cache=False,
        num_retries=0,
        timeout=120,
        max_tokens=4096,
        extra_body={
            "provider": {
                "only": [provider], "order": [provider], "allow_fallbacks": False,
                "require_parameters": True, "data_collection": "deny", "zdr": True,
                "max_price": {"prompt": 0.14, "completion": 0.28},
            },
            "usage": {"include": True},
        },
        extra_headers={"X-OpenRouter-Metadata": "enabled", "X-OpenRouter-Cache": "false"},
    )
    program.set_lm(lm)
    with (root / "tmp/gepa-six-task-current-root/AIMEBench/test.jsonl").open() as handle:
        row = json.loads(next(handle))
    with dspy.context(lm=lm):
        program(problem=row["problem"])
    '''

    assert {"", 0} =
             System.cmd(
               Path.join(root, "tmp/dspy-parity-venv/bin/python"),
               ["-P", "-c", probe, root, base_url, model, provider],
               stderr_to_stdout: true
             )

    assert_receive {:aime_wire, dspy_body, dspy_headers}
    assert Map.drop(imp_body, ["n", "stream"]) == dspy_body
    assert Map.take(imp_body, ["n", "stream"]) == %{"n" => 1, "stream" => false}

    for headers <- [imp_headers, dspy_headers] do
      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "x-openrouter-cache" and value == "false"
             end)

      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "x-openrouter-metadata" and value == "enabled"
             end)
    end
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args])
    output
  end
end
