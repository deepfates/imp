defmodule Imp.BenchmarkTruth.EnsembleDifferentialTest do
  use ExUnit.Case, async: false

  # Requires the pinned DSPy 3.2.1 source checkout and parity venv under tmp/
  # (see CONTRIBUTING.md "Maintainer checks"); run with EVIDENCE_INFRASTRUCTURE=1.
  @moduletag :evidence_infrastructure

  alias Mix.Tasks.Imp.Benchmark.EnsembleDifferential, as: Differential

  @config "benchmarks/config/ensemble-differential-v1.json"

  test "provider-free shared observations match the pinned fixture" do
    expected = @config |> File.read!() |> Jason.decode!() |> get_in(["fixture", "expected"])
    local = Differential.local_observations()

    assert local["shared"] == Map.take(expected, ~w(all_program_count reduced_mean subset_count))
    assert local["deterministic_replay_supported"]
  end

  # build_artifact! validates fixture authority by hashing the pinned DSPy 3.2.1
  # source tree under tmp/, so this row needs the capture environment.
  @tag :requires_dspy_capture
  test "artifact keeps shared observations separate from native extensions" do
    expected = @config |> File.read!() |> Jason.decode!() |> get_in(["fixture", "expected"])

    report = %{
      "schema_version" => 1,
      "fixture_id" => "dspy-ensemble-c1-v1",
      "status" => "passing",
      "provider_free" => true,
      "credential_environment" => %{"provider_credential_names_present" => []},
      "runtime_identity" => %{
        "git_commit" => "29448ae12756abdd14bd8796c819247ebb83673c",
        "git_clean" => true,
        "distribution_version" => "3.2.1"
      },
      "observations" => expected
    }

    artifact = Differential.build_artifact!(report)

    assert artifact["comparison"]["matched"]
    assert artifact["summary"]["matched_claim_count"] == 3

    assert artifact["native_extensions"] == %{
             "dspy_rejects_deterministic" => true,
             "imp_deterministic_replay_supported" => true
           }

    assert "exact sampled membership or Python RNG parity" in artifact["scope"]["not_claimed"]
  end

  test "credential-shaped environment is removed from the Python child" do
    previous = System.get_env("ENSEMBLE_TEST_API_KEY")
    System.put_env("ENSEMBLE_TEST_API_KEY", "dummy-canary")

    try do
      assert {"ENSEMBLE_TEST_API_KEY", nil} in Differential.credential_safe_python_env()
    after
      if previous,
        do: System.put_env("ENSEMBLE_TEST_API_KEY", previous),
        else: System.delete_env("ENSEMBLE_TEST_API_KEY")
    end
  end
end
