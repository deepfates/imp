defmodule Imp.BenchmarkTruth.AvatarActorDifferentialTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Imp.Benchmark.AvatarActorDifferential, as: Differential

  @python "tmp/dspy-parity-venv/bin/python"
  @script "scripts/dspy_avatar_actor_differential.py"
  @config "benchmarks/config/avatar-actor-differential-v1.json"

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

  test "matches only the authenticated shared actor observations", %{report: report} do
    artifact = Differential.build_artifact!(report)
    assert artifact["protocol_id"] == "avatar-actor-c1-v1"
    assert artifact["registry_protocol_id"] == "avatar_actor_differential"
    assert artifact["evidence_tier"] == "C1"
    assert artifact["provider_free"]
    assert artifact["comparison"]["matched"]
    assert artifact["comparison"]["imp"] == artifact["comparison"]["dspy"]
    assert length(artifact["scope"]["claims"]) == 3
    assert length(artifact["scope"]["native_deviations"]) == 3
    assert "provider behavior or model tool selection" in artifact["scope"]["not_claimed"]
    assert "task effectiveness" in artifact["scope"]["not_claimed"]
  end

  test "rejects fabricated observations", %{report: report} do
    tampered = put_in(report, ["observations", "actor_call_count"], 99)

    assert_raise ArgumentError, ~r/receipt or observations are invalid/, fn ->
      Differential.validate_report!(tampered)
    end
  end

  test "scrubs exact and suffixed credential names" do
    names = ["API_KEY", "TOKEN", "AWS_SESSION_TOKEN", "VENDOR_API_KEY", "PGPASSWORD"]
    previous = Map.take(System.get_env(), names)
    Enum.each(names, &System.put_env(&1, "dummy-avatar-actor-canary-never-use"))

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
    assert_raise Mix.Error, ~r/cannot be captured without --require-clean/, fn ->
      Differential.run_capture(["--no-require-clean"], fn -> %{} end)
    end
  end
end
