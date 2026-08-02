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
    end
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
        family="AIMEBench", arm="baseline", seed=17, max_concurrency=8
    )
    tmp = tempfile.TemporaryDirectory()
    args.output = pathlib.Path(tmp.name) / "result.json"
    progress = condition.init_progress(args)
    lm = condition.make_lm(dspy, "task", args)
    baseline = object()
    selected = object()
    assert condition.arm_program("baseline", baseline, selected) is baseline
    assert condition.arm_program("mipro_v2_heavy", baseline, selected) is selected
    assert condition.arm_requires_fresh_state("baseline") is False
    assert condition.arm_requires_fresh_state("gepa_v0_1_4_no_merge") is True
    assert lm.forward(messages=[{"role": "user", "content": "é"}])["id"] == "id"
    usage = condition.runtime_usage()["summary"]["task"]
    assert usage["request_attempts"] == 1
    assert usage["usage_events"] == 1
    assert usage["input_tokens"] == 1
    assert usage["output_tokens"] == 1
    assert usage["cost_usd"] == 0.0
    progress_lines = progress.read_text().splitlines()
    assert len(progress_lines) == 2
    assert progress.stat().st_mode & 0o777 == 0o600
    assert json.loads(progress_lines[1])["sequence"] == 1
    spec = {"split_counts":{"test":1}}
    args.initial_cost_usd = 0.0
    args.max_cost_usd = 1.0
    args.judge_max_input_bytes = 2
    args.judge_max_output_tokens = 16
    admission = condition.baseline_spend_admission(args, spec)
    assert admission["calls"] == {"task_transports":2, "judge_transports":0}
    args.max_cost_usd = 0.000001
    try:
        condition.baseline_spend_admission(args, spec)
    except RuntimeError as error:
        assert "owner cap before transport" in str(error)
    else:
        raise AssertionError("oversized condition reservation was admitted")
    try:
        lm.forward(messages=[{"role": "user", "content": "abc"}])
    except RuntimeError as error:
        assert "before transport" in str(error)
    else:
        raise AssertionError("oversized input reached transport")
    try:
        asyncio.run(lm.aforward(messages=[{"role": "user", "content": "abc"}]))
    except RuntimeError as error:
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
end
