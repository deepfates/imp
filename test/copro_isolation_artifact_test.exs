defmodule Imp.BenchmarkTruth.COPROIsolationArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  alias Imp.BenchmarkTruth.RunContext
  alias Mix.Tasks.Imp.Benchmark.CoproIsolation, as: COPROArtifact

  @python "tmp/dspy-parity-venv/bin/python"
  @script "scripts/dspy_copro_isolation_differential.py"
  @config "benchmarks/config/copro-isolation-differential-v1.json"
  @admission "benchmarks/evidence/admitted/copro_isolation/5cf88e790cdf7fd12ffd6e24396b3512d59655238854b7c6406a24caa82ab37e.json"

  setup_all do
    unless File.exists?(@python) and File.dir?("tmp/dspy-3.2.1/.git") do
      flunk("pinned provider-free DSPy 3.2.1 fixture environment is missing")
    end

    {output, 0} =
      System.cmd(
        Path.expand(@python),
        [Path.expand(@script), "--config", Path.expand(@config)],
        cd: File.cwd!(),
        env: COPROArtifact.credential_safe_python_env(),
        stderr_to_stdout: true
      )

    report = Jason.decode!(output)
    artifact = @admission |> File.read!() |> Jason.decode!()
    %{artifact: artifact, report: report}
  end

  test "pure default admission verifies source-bound C1 receipt without replay", %{
    artifact: artifact
  } do
    assert artifact ==
             COPROArtifact.validate_artifact!(artifact,
               python: "/this-path-must-not-be-executed-by-pure-validation"
             )

    assert artifact["evidence_tier"] == "C1"
    assert artifact["provider_free"]

    assert Map.drop(artifact["source_bindings"], ["authority_ledger_sha256", "task_sha256"]) ==
             Map.drop(COPROArtifact.source_bindings(), [
               "authority_ledger_sha256",
               "task_sha256"
             ])

    assert artifact["dspy_report"]["runtime_identity"]["git_clean"]

    assert artifact["dspy_report"]["runtime_identity"]["git_commit"] ==
             "29448ae12756abdd14bd8796c819247ebb83673c"

    assert artifact["summary"]["retained_exclusions"] == [
             "exact Python RNG parity",
             "provider behavior or effectiveness",
             "full optimizer parity"
           ]
  end

  @tag timeout: 120_000
  test "fresh replay is an explicit additional operation", %{artifact: artifact} do
    assert artifact ==
             COPROArtifact.validate_artifact!(artifact,
               fresh_replay: true,
               python: Path.expand(@python)
             )
  end

  test "admission rejects fabricated deterministic observations", %{artifact: artifact} do
    tampered =
      artifact
      |> payload()
      |> put_in(["dspy_report", "observations", "evaluation_order"], ["base"])
      |> rewrap_clean(artifact["git_sha"])

    assert_raise ArgumentError, ~r/deterministic call\/order\/deduplication/, fn ->
      COPROArtifact.validate_artifact!(tampered)
    end
  end

  test "admission rejects removed provider, effectiveness, RNG, or parity exclusions", %{
    artifact: artifact
  } do
    tampered =
      artifact
      |> payload()
      |> put_in(
        ["dspy_report", "scope", "not_claimed"],
        ["exact Python RNG parity", "full optimizer parity"]
      )
      |> put_in(["scope", "not_claimed"], ["exact Python RNG parity", "full optimizer parity"])
      |> rewrap_clean(artifact["git_sha"])

    assert_raise ArgumentError, ~r/identity or scope is invalid/, fn ->
      COPROArtifact.validate_artifact!(tampered)
    end
  end

  test "admission rejects unauthenticated or dirty DSPy runtime identity", %{artifact: artifact} do
    tampered =
      artifact
      |> payload()
      |> put_in(["dspy_report", "runtime_identity", "git_clean"], false)
      |> rewrap_clean(artifact["git_sha"])

    assert_raise ArgumentError, ~r/pinned clean DSPy 3.2.1 source/, fn ->
      COPROArtifact.validate_artifact!(tampered)
    end
  end

  test "admission rejects artifacts not captured from clean committed Imp source", %{
    report: report
  } do
    artifact = report |> COPROArtifact.build_artifact!() |> rewrap("dirty", git_sha!())

    assert_raise ArgumentError, ~r/clean checkout/, fn ->
      COPROArtifact.validate_artifact!(artifact)
    end
  end

  test "child environment removes exact and suffixed credential names" do
    names = [
      "API_KEY",
      "TOKEN",
      "SECRET",
      "AUTHORIZATION",
      "VENDOR_API_KEY",
      "VENDOR_CLIENT_SECRET",
      "PGPASSWORD"
    ]

    previous = Map.take(System.get_env(), names)
    Enum.each(names, &System.put_env(&1, "dummy-copro-canary-never-use"))

    try do
      env = Map.new(COPROArtifact.credential_safe_python_env())
      assert Enum.all?(names, &(env[&1] == nil))
      assert env["PYTHON_DOTENV_DISABLED"] == "1"
      assert env["PYTHONPATH"] == Path.expand("tmp/dspy-3.2.1")
    after
      Enum.each(names, fn name ->
        case previous do
          %{^name => value} -> System.put_env(name, value)
          %{} -> System.delete_env(name)
        end
      end)
    end
  end

  test "capture cannot downgrade the clean-source requirement" do
    assert_raise Mix.Error, ~r/cannot be captured without --require-clean/, fn ->
      COPROArtifact.run_with_runner(["--no-require-clean"], fn -> %{} end)
    end
  end

  test "unrelated authority-ledger changes do not revoke the admitted receipt" do
    artifact = @admission |> File.read!() |> Jason.decode!()
    historical = artifact["source_bindings"]
    current = COPROArtifact.source_bindings()

    refute historical["authority_ledger_sha256"] == current["authority_ledger_sha256"]

    assert Map.drop(historical, ["authority_ledger_sha256", "task_sha256"]) ==
             Map.drop(current, ["authority_ledger_sha256", "task_sha256"])

    assert COPROArtifact.validate_artifact!(artifact) == artifact
  end

  defp payload(artifact), do: Map.drop(artifact, ["generated_at", "git_sha", "run_context"])
  defp rewrap_clean(payload, revision), do: rewrap(payload, "clean", revision)

  defp rewrap(payload, workspace_state, revision) do
    context =
      RunContext.new!(
        source_commits: %{
          "imp" => "deepfates/imp@#{revision}",
          "dspy" => "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"
        },
        workspace_state: workspace_state,
        environment: %{"kind" => "synthetic", "purpose" => "validator-test"},
        inputs: payload["source_bindings"]
      )

    RunContext.finish(context, payload)
  end

  defp git_sha! do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(sha)
  end
end
