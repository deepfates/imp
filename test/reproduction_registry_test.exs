defmodule DSEx.ReproductionRegistryTest do
  use ExUnit.Case, async: false

  alias DSEx.ReproductionRegistry

  @registry "benchmarks/reproductions.json"
  @authorities "benchmarks/authorities.json"

  test "registry covers every authority family and all references resolve" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)
    authorities = DSEx.EvidenceAuthorities.load!(@authorities)

    assert Enum.sort(Enum.uniq(Enum.map(registry["features"], & &1["authority_family"]))) ==
             Enum.sort(Enum.map(authorities["families"], & &1["id"]))
  end

  test "generated documentation agrees with the registry" do
    Mix.Task.reenable("dsex.reproductions")
    Mix.Tasks.Dsex.Reproductions.run(["--check"])
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

    bad_task = put_in(registry, ["protocols", "core_trace", "task"], "dsex.not_real")

    assert_raise ArgumentError, ~r/does not resolve/, fn ->
      ReproductionRegistry.validate!(bad_task, authorities, File.cwd!())
    end

    feature_index = Enum.find_index(registry["features"], &(&1["id"] == "optimizer_miprov2"))

    wildcard =
      registry
      |> put_in(["features", Access.at(feature_index), "evidence", "artifact"], "tmp/*.json")

    assert_raise ArgumentError, ~r/immutable, not a glob/, fn ->
      ReproductionRegistry.validate!(wildcard, authorities, File.cwd!())
    end

    tampered =
      put_in(
        registry,
        ["features", Access.at(feature_index), "evidence", "artifact_sha256"],
        String.duplicate("0", 64)
      )

    assert_raise ArgumentError, ~r/artifact digest mismatch/, fn ->
      ReproductionRegistry.validate!(tampered, authorities, File.cwd!())
    end

    inflated =
      registry
      |> put_in(["features", Access.at(feature_index), "evidence", "tier"], "t3")
      |> put_in(["features", Access.at(feature_index), "evidence", "claim_state"], "green")

    assert_raise ArgumentError, ~r/cannot be green with open constraints/, fn ->
      ReproductionRegistry.validate!(inflated, authorities, File.cwd!())
    end
  end

  test "rejects a source-manifest omission inherited from the authority ledger" do
    root =
      Path.join(
        System.tmp_dir!(),
        "dsex-reproduction-authority-#{System.unique_integer([:positive])}"
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
end
