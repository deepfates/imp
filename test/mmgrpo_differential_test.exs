defmodule Imp.BenchmarkTruth.MmgrpoDifferentialTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Imp.Benchmark.MmgrpoDifferential, as: Differential

  @config "benchmarks/config/mmgrpo-differential-v1.json"
  @commit "29448ae12756abdd14bd8796c819247ebb83673c"

  test "provider-free Imp observations match the pinned fixture" do
    expected = @config |> File.read!() |> Jason.decode!() |> get_in(["fixture", "expected"])
    assert Differential.local_observations() == expected
  end

  test "artifact is narrow, matched, source-bound, and explicit about exclusions" do
    expected = @config |> File.read!() |> Jason.decode!() |> get_in(["fixture", "expected"])

    report = %{
      "schema_version" => 1,
      "fixture_id" => "dspy-mmgrpo-c1-v1",
      "status" => "passing",
      "provider_free" => true,
      "credential_environment" => %{"provider_credential_names_present" => []},
      "runtime_identity" => %{
        "git_commit" => @commit,
        "git_clean" => true,
        "distribution_version" => "3.2.1"
      },
      "observations" => expected
    }

    artifact = Differential.build_artifact!(report)
    bindings = Differential.source_bindings()

    assert artifact["comparison"]["matched"]
    assert artifact["summary"]["matched_claim_count"] == 4
    assert bindings["authority_family_sha256"] =~ ~r/^sha256:[0-9a-f]{64}$/
    refute Map.has_key?(bindings, "authority_ledger_sha256")
    assert "exact shuffled order or Python RNG parity" in artifact["scope"]["not_claimed"]
    assert "training effectiveness or model quality" in artifact["scope"]["not_claimed"]
  end

  test "credential-shaped environment is removed from the Python child" do
    previous = System.get_env("MMGRPO_TEST_API_KEY")
    System.put_env("MMGRPO_TEST_API_KEY", "dummy-canary")

    try do
      assert {"MMGRPO_TEST_API_KEY", nil} in Differential.credential_safe_python_env()
    after
      if previous,
        do: System.put_env("MMGRPO_TEST_API_KEY", previous),
        else: System.delete_env("MMGRPO_TEST_API_KEY")
    end
  end
end
