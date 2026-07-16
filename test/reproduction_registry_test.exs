defmodule Imp.ReproductionRegistryTest do
  use ExUnit.Case, async: false

  alias Imp.ReproductionRegistry

  @registry "benchmarks/reproductions.json"
  @authorities "benchmarks/authorities.json"

  test "registry covers every authority family and all references resolve" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)
    authorities = Imp.EvidenceAuthorities.load!(@authorities)

    assert Enum.sort(Enum.uniq(Enum.map(registry["features"], & &1["authority_family"]))) ==
             Enum.sort(Enum.map(authorities["families"], & &1["id"]))
  end

  test "generated documentation agrees with the registry" do
    Mix.Task.reenable("imp.reproductions")
    Mix.Tasks.Imp.Reproductions.run(["--check"])
  end

  test "rejects duplicate ownership and omitted authority families" do
    registry = read_json!(@registry)
    authorities = read_json!(@authorities)
    [first | rest] = registry["features"]

    duplicate = put_in(registry, ["features"], [first, first | rest])

    assert_raise ArgumentError, ~r/feature ids must be unique/, fn ->
      ReproductionRegistry.validate!(duplicate, authorities, File.cwd!())
    end

    omitted = put_in(registry, ["features"], rest)

    assert_raise ArgumentError, ~r/reproduction coverage differs/, fn ->
      ReproductionRegistry.validate!(omitted, authorities, File.cwd!())
    end
  end

  test "rejects nonexistent tasks, wildcard artifacts, and inflated claims" do
    registry = read_json!(@registry)
    authorities = read_json!(@authorities)

    bad_task = put_in(registry, ["protocols", "core_trace", "task"], "imp.not_real")

    assert_raise ArgumentError, ~r/does not resolve/, fn ->
      ReproductionRegistry.validate!(bad_task, authorities, File.cwd!())
    end

    feature_index = Enum.find_index(registry["features"], &(&1["id"] == "optimizer_miprov2"))

    wildcard =
      registry
      |> put_in(
        ["features", Access.at(feature_index), "admitted_evidence", "artifact"],
        "tmp/*.json"
      )

    assert_raise ArgumentError, ~r/immutable, not a glob/, fn ->
      ReproductionRegistry.validate!(wildcard, authorities, File.cwd!())
    end

    tampered =
      put_in(
        registry,
        ["features", Access.at(feature_index), "admitted_evidence", "artifact_sha256"],
        String.duplicate("0", 64)
      )

    assert_raise ArgumentError, ~r/artifact digest mismatch/, fn ->
      ReproductionRegistry.validate!(tampered, authorities, File.cwd!())
    end

    inflated =
      put_in(
        registry,
        ["features", Access.at(feature_index), "admitted_evidence", "claim_state"],
        "green"
      )

    assert_raise ArgumentError, ~r/must not cache mutable constraints or claim state/, fn ->
      ReproductionRegistry.validate!(inflated, authorities, File.cwd!())
    end
  end

  test "decodes admitted artifacts and rejects forged contracts even with matching digests" do
    registry = read_json!(@registry)
    authorities = read_json!(@authorities)

    assert_rejects_forged_artifact!(registry, authorities, "semantic_f1", fn artifact ->
      Map.put(artifact, "schema_version", 99)
    end)

    assert_rejects_forged_artifact!(registry, authorities, "optimizer_miprov2", fn artifact ->
      Map.put(artifact, "runner", "forged-runner")
    end)

    assert_rejects_forged_artifact!(registry, authorities, "optimize_anything", fn artifact ->
      put_in(artifact, ["source", "mode"], "forged_source")
    end)

    assert_rejects_forged_artifact!(registry, authorities, "optimizer_simba", fn artifact ->
      Map.put(artifact, "claim_scope", "forged contract")
    end)

    assert_rejects_forged_artifact!(registry, authorities, "optimizer_simba", fn artifact ->
      put_in(artifact, ["identity", "dspy_authority", "commit"], "forged-source")
    end)
  end

  test "rejects validators claimed by protocols without admitted artifacts" do
    registry = read_json!(@registry)
    authorities = read_json!(@authorities)

    forged =
      put_in(registry, ["protocols", "package_gate", "artifact_validator"], %{
        "mode" => "module",
        "module" => "Elixir.Imp.BenchmarkTruth.ReproductionArtifactValidator",
        "function" => "validate!",
        "arity" => 2
      })

    assert_raise ArgumentError,
                 ~r/must not declare an artifact validator without admitted artifacts/,
                 fn ->
                   ReproductionRegistry.validate!(forged, authorities, File.cwd!())
                 end
  end

  test "rejects a source-manifest omission inherited from the authority ledger" do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-reproduction-authority-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "benchmarks"))
    File.cp!(@registry, Path.join(root, @registry))
    File.cp!(@authorities, Path.join(root, @authorities))

    assert_raise ArgumentError, ~r/authority_sources/, fn ->
      ReproductionRegistry.load!(Path.join(root, @registry),
        authority_path: Path.join(root, @authorities),
        root: root
      )
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp assert_rejects_forged_artifact!(registry, authorities, feature_id, mutate) do
    feature_index = Enum.find_index(registry["features"], &(&1["id"] == feature_id))

    artifact_path =
      get_in(registry, ["features", Access.at(feature_index), "admitted_evidence", "artifact"])

    artifact = artifact_path |> File.read!() |> Jason.decode!() |> mutate.()

    forged_path =
      "benchmarks/results/reproduction-registry-forged-#{System.unique_integer([:positive])}.json"

    on_exit(fn -> File.rm!(forged_path) end)
    File.write!(forged_path, Jason.encode!(artifact, pretty: true))

    forged =
      registry
      |> put_in(
        ["features", Access.at(feature_index), "admitted_evidence", "artifact"],
        forged_path
      )
      |> put_in(
        ["features", Access.at(feature_index), "admitted_evidence", "artifact_sha256"],
        forged_path
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
      )

    assert_raise ArgumentError, ~r/admitted artifact failed protocol/, fn ->
      ReproductionRegistry.validate!(forged, authorities, File.cwd!())
    end
  end
end
