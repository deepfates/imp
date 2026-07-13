defmodule DSEx.UpstreamAuthorityRegistryTest do
  use ExUnit.Case, async: true

  alias DSEx.UpstreamAuthorityRegistry, as: Registry

  test "UpstreamFidelity resolves stable and tracking pins from the canonical registry" do
    registry = Registry.load!()
    stable = Registry.authority!(registry, "dspy_stable_upstream_fidelity")
    tracking = Registry.authority!(registry, "t1_instruction_optimizer_differential_contract")
    report = DSEx.UpstreamFidelity.report()

    assert report.baseline.version == stable["version"]
    assert report.baseline.git_sha == stable["commit"]
    assert report.baseline.api_manifest_sha256 == stable["source_hashes"]["api_manifest"]
    assert report.prerelease_tracking.version == tracking["version"]
    assert report.prerelease_tracking.git_sha == tracking["commit"]
    assert report.upstream_authority_registry == registry
  end

  test "registry and UpstreamFidelity fail closed on source hash drift" do
    registry = Registry.load!()

    drifted =
      put_in(
        registry,
        ["authorities", "dspy_stable", "source_hashes", "api_manifest"],
        String.duplicate("0", 63) <> "x"
      )

    path = write_registry!(drifted)

    assert_raise ArgumentError, ~r/source hash.*lowercase SHA digest/, fn ->
      Registry.load!(path)
    end

    assert_raise ArgumentError, ~r/invalid upstream authority registry/, fn ->
      DSEx.UpstreamFidelity.report(registry_path: path)
    end
  end

  test "registry rejects missing files and incompatible contract bindings" do
    missing = Path.join(System.tmp_dir!(), "missing-upstream-registry-#{nonce()}.json")

    assert_raise ArgumentError, ~r/invalid upstream authority registry/, fn ->
      Registry.load!(missing)
    end

    registry = Registry.load!()

    incompatible =
      put_in(
        registry,
        ["contracts", "t1_instruction_optimizer_differential_contract", "authority"],
        "req_llm"
      )

    assert_raise ArgumentError, ~r/is not declared by authority req_llm/, fn ->
      incompatible |> write_registry!() |> Registry.load!()
    end
  end

  test "registry requires the complete canonical authority set" do
    incomplete = Registry.load!() |> update_in(["authorities"], &Map.delete(&1, "req_llm"))

    assert_raise ArgumentError, ~r/missing required authorities: req_llm/, fn ->
      incomplete |> write_registry!() |> Registry.load!()
    end
  end

  defp write_registry!(registry) do
    path = Path.join(System.tmp_dir!(), "upstream-authority-registry-#{nonce()}.json")
    File.write!(path, Jason.encode!(registry))
    path
  end

  defp nonce, do: System.unique_integer([:positive, :monotonic])
end
