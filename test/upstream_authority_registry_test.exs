defmodule Imp.UpstreamAuthorityRegistryTest do
  use ExUnit.Case, async: true

  alias Imp.UpstreamAuthorityRegistry, as: Registry

  test "UpstreamFidelity resolves stable and tracking pins from the canonical registry" do
    registry = Registry.load!()
    stable = Registry.authority!(registry, "dspy_stable_upstream_fidelity")
    tracking = Registry.authority!(registry, "t1_instruction_optimizer_differential_contract")

    optimize_anything =
      Registry.authority!(registry, "optimize_anything_upstream_differential_protocol")

    swe_bench =
      Registry.authority!(registry, "optimize_anything_swe_bench_flask_5014_dataset")

    report = Imp.UpstreamFidelity.report()

    assert report.baseline.version == stable["version"]
    assert report.baseline.git_sha == stable["commit"]
    assert report.baseline.api_manifest_sha256 == stable["source_hashes"]["api_manifest"]
    assert report.prerelease_tracking.version == tracking["version"]
    assert report.prerelease_tracking.git_sha == tracking["commit"]
    assert optimize_anything["commit"] == "58cdf89d856f2fbc174991b89076eccdcf68e4ca"
    assert map_size(optimize_anything["source_hashes"]) == 10
    assert swe_bench["commit"] == "91aa3ed51b709be6457e12d00300a6a596d4c6a3"
    assert report.upstream_authority_registry == registry
  end

  test "registry and UpstreamFidelity fail closed on source hash drift" do
    ledger = read_ledger!()

    drifted =
      put_in(
        ledger,
        ["pinned_sources", "dspy_stable", "source_hashes", "api_manifest"],
        String.duplicate("0", 63) <> "x"
      )

    path = write_registry!(drifted)

    assert_raise ArgumentError, ~r/source hash.*lowercase SHA digest/, fn ->
      Registry.load!(path)
    end

    assert_raise ArgumentError, ~r/invalid upstream authority ledger/, fn ->
      Imp.UpstreamFidelity.report(registry_path: path)
    end
  end

  test "registry rejects missing files and incompatible contract bindings" do
    missing = Path.join(System.tmp_dir!(), "missing-upstream-registry-#{nonce()}.json")

    assert_raise ArgumentError, ~r/invalid upstream authority ledger/, fn ->
      Registry.load!(missing)
    end

    ledger = read_ledger!()

    incompatible =
      put_in(
        ledger,
        ["contracts", "t1_instruction_optimizer_differential_contract", "authority"],
        "req_llm"
      )

    assert_raise ArgumentError, ~r/must bind authority dspy_instruction_optimizers/, fn ->
      incompatible |> write_registry!() |> Registry.load!()
    end
  end

  test "registry requires the complete canonical authority set" do
    incomplete = read_ledger!() |> update_in(["pinned_sources"], &Map.delete(&1, "req_llm"))

    assert_raise ArgumentError, ~r/contract authority req_llm is not pinned/, fn ->
      incomplete |> write_registry!() |> Registry.load!()
    end
  end

  defp read_ledger! do
    Registry.path() |> File.read!() |> Jason.decode!()
  end

  defp write_registry!(registry) do
    path = Path.join(System.tmp_dir!(), "upstream-authority-registry-#{nonce()}.json")
    File.write!(path, Jason.encode!(registry))
    path
  end

  defp nonce, do: System.unique_integer([:positive, :monotonic])
end
