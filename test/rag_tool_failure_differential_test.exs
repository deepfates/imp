defmodule RagToolFailureDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  alias Mix.Tasks.Imp.Benchmark.RagToolFailureDifferential, as: Differential

  test "executes the exact preregistered schedule in Imp and authenticated DSPy" do
    out = tmp_dir("rag-tool-failure")
    previous_key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "dummy-parent-canary-never-sent")

    on_exit(fn ->
      if previous_key,
        do: System.put_env("OPENAI_API_KEY", previous_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rag_tool_failure_differential")

      Differential.run([
        "--no-require-clean",
        "--out",
        out,
        "--python",
        Path.expand("tmp/dspy-parity-venv/bin/python")
      ])
    end)

    [path] = Path.wildcard(Path.join(out, "rag-tool-failure-differential-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["evidence_level"] ==
             "C2_provider_free_operational_failure_differential"

    assert artifact["admission_requires_clean_source"]
    assert artifact["summary"]["provider_free_failure_differential_complete"]
    assert artifact["summary"]["matched_rows"] == 6
    refute artifact["summary"]["model_tool_selection_effectiveness"]
    refute artifact["summary"]["retrieval_quality_effectiveness"]
    refute artifact["summary"]["wall_clock_timeout_parity"]
    assert Enum.all?(artifact["rows"], & &1["matched"])

    ids = Enum.map(artifact["rows"], & &1["id"])

    assert ids == [
             "transient_retry_then_success",
             "retriever_timeout_observed",
             "idempotent_replay",
             "unknown_tool_then_finish",
             "failing_tool_then_finish",
             "iteration_budget_terminal"
           ]

    assert get_in(artifact, ["dspy", "source", "authority_manifest_verified_files"]) == 296
    assert get_in(artifact, ["dspy", "source", "git_tag"]) == "3.2.1"
    assert get_in(artifact, ["dspy", "source", "distribution_version"]) == "3.2.1"
    assert get_in(artifact, ["dspy", "source", "module_version"]) == "3.2.0"
    assert get_in(artifact, ["dspy", "source", "git_clean_before"])
    assert get_in(artifact, ["dspy", "source", "git_clean_after"])

    assert artifact["dspy"]["credential_isolation"] == %{
             "checked_after_import" => true,
             "checked_before_import" => true,
             "checked_during_every_lm_call" => true,
             "dotenv_disabled" => true,
             "dummy_canary_present_before_scrub" => true,
             "only_dummy_canary_present_before_scrub" => true,
             "sensitive_values_present_after_scrub" => false
           }

    assert Differential.validate_artifact!(artifact,
             require_clean: false,
             fresh_replay: true
           ) == artifact

    if get_in(artifact, ["run_context", "workspace", "state"]) == "dirty" do
      assert_raise ArgumentError, ~r/requires a clean source checkout/, fn ->
        Differential.validate_artifact!(artifact)
      end
    end
  end

  test "raw comparison rejects missing, duplicate, reordered, altered, and unauthenticated evidence" do
    artifact = run_artifact("rag-tool-failure-adversarial")
    imp = side_report(artifact, "imp")
    dspy = side_report(artifact, "dspy")

    mutations = [
      Map.update!(dspy, "rows", &tl/1),
      Map.update!(dspy, "rows", fn [row | rows] -> [row, row | rows] end),
      Map.update!(dspy, "rows", &Enum.reverse/1),
      put_in(dspy, ["rows", Access.at(0), "trace", Access.at(0), "outcome"], "success"),
      put_in(dspy, ["rows", Access.at(0), "terminal", "state"], "success")
    ]

    Enum.each(mutations, fn mutation ->
      assert_raise Mix.Error, ~r/(exact preregistered|does not recompute)/, fn ->
        Differential.compare_reports!(imp, mutation)
      end
    end)

    wrong_commit = put_in(dspy, ["source", "commit"], String.duplicate("0", 40))

    assert_raise Mix.Error, ~r/unauthenticated or stale/, fn ->
      Differential.compare_reports!(imp, wrong_commit)
    end

    wrong_runtime_hash = put_in(dspy, ["source", "authority_manifest_verified_files"], 2)

    assert_raise Mix.Error, ~r/unauthenticated or stale/, fn ->
      Differential.compare_reports!(imp, wrong_runtime_hash)
    end
  end

  test "Python runner rejects fake and dirty DSPy source trees before import" do
    fake = tmp_dir("fake-dspy")
    File.mkdir_p!(Path.join(fake, "dspy"))
    File.write!(Path.join(fake, "dspy/__init__.py"), "__version__ = '3.2.1'\n")

    {fake_output, fake_status} = run_python_source(fake)
    assert fake_status != 0
    assert fake_output =~ "not a git checkout"

    dirty = tmp_dir("dirty-dspy")

    {_output, 0} =
      System.cmd(
        "git",
        [
          "clone",
          "--quiet",
          "--no-hardlinks",
          Path.expand("tmp/dspy-3.2.1"),
          dirty
        ],
        stderr_to_stdout: true
      )

    react_path = Path.join(dirty, "dspy/predict/react.py")
    File.write!(react_path, File.read!(react_path) <> "\n# fixture tamper\n")

    {dirty_output, dirty_status} = run_python_source(dirty)
    assert dirty_status != 0
    assert dirty_output =~ "not clean pinned 3.2.1"
  end

  test "validator rejects a freshly enveloped forged summary instead of trusting booleans" do
    artifact = run_artifact("rag-tool-failure-forged-summary")

    payload =
      artifact
      |> Map.drop(["generated_at", "git_sha", "run_context"])
      |> put_in(["summary", "matched_rows"], 0)
      |> put_in(["summary", "provider_free_failure_differential_complete"], true)

    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{
          "imp" => "deepfates/imp@#{git_sha()}",
          "dspy" => "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"
        },
        code_source: "imp",
        workspace_state: "synthetic",
        environment: %{"kind" => "synthetic"},
        inputs: Differential.source_bindings(read_config())
      )

    forged = Imp.BenchmarkTruth.RunContext.finish(context, payload)

    assert_raise ArgumentError, ~r/content does not recompute/, fn ->
      Differential.validate_artifact!(forged, require_clean: false)
    end
  end

  defp run_artifact(label) do
    out = tmp_dir(label)

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.rag_tool_failure_differential")

      Differential.run([
        "--no-require-clean",
        "--out",
        out,
        "--python",
        Path.expand("tmp/dspy-parity-venv/bin/python")
      ])
    end)

    [path] = Path.wildcard(Path.join(out, "rag-tool-failure-differential-*.json"))
    path |> File.read!() |> Jason.decode!()
  end

  defp side_report(artifact, side) do
    artifact[side]
    |> Map.put("rows", Enum.map(artifact["rows"], & &1[side]))
  end

  defp read_config do
    "benchmarks/config/rag-tool-failure-differential-v1.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp run_python_source(source) do
    System.cmd(
      Path.expand("tmp/dspy-parity-venv/bin/python"),
      [
        Path.expand("scripts/dspy_rag_tool_failure_differential.py"),
        "--dspy-source",
        source
      ],
      stderr_to_stdout: true,
      env: [
        {"IMP_RAG_FAILURE_DUMMY_API_KEY", "dummy-canary-not-a-credential"},
        {"PYTHON_DOTENV_DISABLED", "1"}
      ]
    )
  end

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "imp-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
