defmodule Imp.BenchmarkTruth.ClassicalOptimizerDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  alias Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential, as: Differential

  @python "tmp/dspy-parity-venv/bin/python"
  @script "scripts/dspy_classical_optimizer_differential.py"
  @config "benchmarks/config/classical-optimizer-differential-v1.json"
  @bootstrap_admission "benchmarks/evidence/admitted/bootstrap_few_shot_differential/9b89dac91786fb2360c810f3122d2a755fc930228253730cd91de6a3b2df2094.json"

  setup_all do
    {output, 0} =
      System.cmd(
        Path.expand(@python),
        [Path.expand(@script), "--config", Path.expand(@config)],
        cd: File.cwd!(),
        env: Differential.credential_safe_python_env(),
        stderr_to_stdout: false
      )

    %{report: Jason.decode!(output)}
  end

  test "family-specific artifacts bind exact matching observations and retain exclusions", %{
    report: report
  } do
    for {family, registry_id} <- [
          {"bootstrap_few_shot", "bootstrap_few_shot_differential"},
          {"random_search", "random_search_differential"}
        ] do
      artifact = Differential.build_artifact!(family, report)
      assert artifact["registry_protocol_id"] == registry_id
      assert artifact["evidence_tier"] == "C1"
      assert artifact["provider_free"]
      assert artifact["comparison"]["matched"]
      assert artifact["comparison"]["imp"] == artifact["comparison"]["dspy"]
      assert "exact Python RNG parity" in artifact["scope"]["not_claimed"]
      assert "provider behavior or effectiveness" in artifact["scope"]["not_claimed"]
      assert "full optimizer parity" in artifact["scope"]["not_claimed"]
    end
  end

  test "report validation rejects fabricated observations", %{report: report} do
    tampered = put_in(report, ["observations", "bootstrap_few_shot", "attempt_count"], 99)

    assert_raise ArgumentError, ~r/receipt or observations are invalid/, fn ->
      Differential.validate_report!(tampered)
    end
  end

  test "child environment removes exact and suffixed credential names" do
    names = ["API_KEY", "TOKEN", "SECRET", "VENDOR_API_KEY", "VENDOR_CLIENT_SECRET", "PGPASSWORD"]
    previous = Map.take(System.get_env(), names)
    Enum.each(names, &System.put_env(&1, "dummy-classical-canary-never-use"))

    try do
      env = Map.new(Differential.credential_safe_python_env())
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

  test "capture cannot downgrade clean-source requirements" do
    for family <- ~w(bootstrap_few_shot random_search) do
      assert_raise Mix.Error, ~r/cannot be captured without --require-clean/, fn ->
        Differential.run_family(family, ["--no-require-clean"], fn -> %{} end)
      end
    end
  end

  test "an unrelated authority-ledger update does not revoke immutable evidence" do
    artifact = @bootstrap_admission |> File.read!() |> Jason.decode!()
    historical = artifact["source_bindings"]
    current = Differential.source_bindings("bootstrap_few_shot")

    refute historical["authority_ledger_sha256"] == current["authority_ledger_sha256"]

    assert Map.drop(historical, ["authority_ledger_sha256", "task_sha256"]) ==
             Map.drop(current, ["authority_ledger_sha256", "task_sha256"])

    assert Differential.validate_artifact!("bootstrap_few_shot_differential", artifact) ==
             artifact
  end
end
