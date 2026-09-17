defmodule Imp.UpstreamAuthorityRegistryTest do
  use ExUnit.Case, async: true

  alias Imp.UpstreamAuthorityRegistry, as: Registry

  test "registry resolves pinned authorities for every canonical contract" do
    registry = Registry.load!()

    stable = Registry.authority!(registry, "dspy_stable_upstream_fidelity")
    assert stable["version"] != ""
    assert stable["commit"] =~ ~r/^[0-9a-f]{40}$/
    assert stable["source_hashes"]["api_manifest"] =~ ~r/^[0-9a-f]{64}$/

    optimize_anything =
      Registry.authority!(registry, "optimize_anything_upstream_differential_protocol")

    assert optimize_anything["commit"] == "58cdf89d856f2fbc174991b89076eccdcf68e4ca"
    assert map_size(optimize_anything["source_hashes"]) == 10

    swe_bench = Registry.authority!(registry, "optimize_anything_swe_bench_flask_5014_dataset")
    assert swe_bench["commit"] == "91aa3ed51b709be6457e12d00300a6a596d4c6a3"
  end

  test "registry fails closed on source hash drift" do
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
