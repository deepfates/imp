defmodule Imp.BenchmarkTruth.ClassicalOptimizerDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  alias Mix.Tasks.Imp.Benchmark.ClassicalOptimizerDifferential, as: Differential

  @python "tmp/dspy-parity-venv/bin/python"
  @script "scripts/dspy_classical_optimizer_differential.py"
  @config "benchmarks/config/classical-optimizer-differential-v1.json"
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

  test "semantic source identity ignores documentation but detects executable changes" do
    first = """
    defmodule Sample do
      @moduledoc "first explanation"
      @doc "first function explanation"
      def value(input), do: input + 1
    end
    """

    documentation_only = """
    # A comment is not runtime behavior.
    defmodule Sample do
      @moduledoc "a completely different explanation"
      @doc "different function prose"

      def value(input), do: input + 1
    end
    """

    executable_change = """
    defmodule Sample do
      def value(input), do: input + 2
    end
    """

    assert Imp.BenchmarkTruth.SemanticSource.digest(first) ==
             Imp.BenchmarkTruth.SemanticSource.digest(documentation_only)

    refute Imp.BenchmarkTruth.SemanticSource.digest(first) ==
             Imp.BenchmarkTruth.SemanticSource.digest(executable_change)
  end
end
