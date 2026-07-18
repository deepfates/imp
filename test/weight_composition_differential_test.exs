defmodule Imp.BenchmarkTruth.WeightCompositionDifferentialTest do
  use ExUnit.Case, async: false

  # Requires the pinned DSPy 3.2.1 source checkout and parity venv under tmp/
  # (see CONTRIBUTING.md "Maintainer checks"); run with EVIDENCE_INFRASTRUCTURE=1.
  @moduletag :evidence_infrastructure

  alias Mix.Tasks.Imp.Benchmark.WeightCompositionDifferential, as: Differential

  @python "tmp/dspy-parity-venv/bin/python"
  @script "scripts/dspy_weight_composition_differential.py"
  @config "benchmarks/config/weight-composition-differential-v1.json"

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

  test "family artifacts bind shared observations and classify native deviations", %{
    report: report
  } do
    bootstrap = Differential.build_artifact!("bootstrap_finetune", report)
    assert bootstrap["evidence_tier"] == "C1"
    assert bootstrap["provider_free"]
    assert bootstrap["comparison"]["shared_matched"]

    assert bootstrap["comparison"]["deviation"]["classification"] ==
             "intentional_corrective_deviation"

    assert bootstrap["comparison"]["dspy"]["dspy_deviation"]["requested_predictor_0_rows"] == [
             "first",
             "second"
           ]

    assert bootstrap["comparison"]["imp"]["imp_native"]["requested_predictor_0_rows"] == ["first"]
    assert "provider behavior or effectiveness" in bootstrap["scope"]["not_claimed"]

    together = Differential.build_artifact!("better_together", report)
    assert together["comparison"]["shared_matched"]

    assert together["comparison"]["deviation"]["classification"] ==
             "bounded_beam_native_extension"

    assert together["comparison"]["imp"]["shared"]["selected_with_validation"] == "p"
    assert "exact Python shuffle order" in together["scope"]["not_claimed"]
    assert "provider behavior or effectiveness" in together["scope"]["not_claimed"]
  end

  test "report validation rejects fabricated observations", %{report: report} do
    tampered =
      put_in(
        report,
        ["observations", "better_together", "shared", "selected_with_validation"],
        "p -> w"
      )

    assert_raise ArgumentError, ~r/receipt or observations are invalid/, fn ->
      Differential.validate_report!(tampered)
    end
  end

  test "child environment removes exact and suffixed credential names" do
    names = ["API_KEY", "TOKEN", "SECRET", "VENDOR_API_KEY", "VENDOR_CLIENT_SECRET", "PGPASSWORD"]
    previous = Map.take(System.get_env(), names)
    Enum.each(names, &System.put_env(&1, "dummy-weight-canary-never-use"))

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
    for family <- ~w(bootstrap_finetune better_together) do
      assert_raise Mix.Error, ~r/cannot be captured without --require-clean/, fn ->
        Differential.run_family(family, ["--no-require-clean"], fn -> %{} end)
      end
    end
  end
end
