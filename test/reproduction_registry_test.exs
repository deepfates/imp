defmodule Imp.ReproductionRegistryTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

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

  test "BFCL scorer agreement is registered as benchmark infrastructure, not ReAct behavior" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)
    protocol = get_in(registry, ["protocols", "bfcl_shaped_scorer"])
    feature = Enum.find(registry["features"], &(&1["id"] == "bfcl_scorer_infrastructure"))
    react = Enum.find(registry["features"], &(&1["id"] == "react"))

    assert protocol["mode"] == "provider_free"
    assert protocol["max_tier"] == "t1"
    assert protocol["task"] == "imp.benchmark.bfcl_adapted"
    assert protocol["args"] == ["--require-clean"]
    assert protocol["manifest"] == "benchmarks/config/bfcl-adapted-differential-v1.json"
    assert protocol["artifact_validator"]["function"] == "validate!"

    assert feature["public_surfaces"] == ["mix imp.benchmark.bfcl_adapted"]
    assert feature["protocol_ids"] == ["bfcl_shaped_scorer"]

    assert feature["admitted_evidence"] == %{
             "tier" => "t1",
             "artifact" =>
               "benchmarks/evidence/admitted/bfcl_shaped_scorer/91b95e1d7308dafdfd62c20dbb133179c4722fe5e023ced013341f3c2c0849ea.json",
             "artifact_sha256" =>
               "91b95e1d7308dafdfd62c20dbb133179c4722fe5e023ced013341f3c2c0849ea",
             "protocol_id" => "bfcl_shaped_scorer"
           }

    refute "bfcl_shaped_scorer" in react["protocol_ids"]
  end

  test "COPRO isolation has pure provider-free admitted T1 evidence" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)
    protocol = get_in(registry, ["protocols", "copro_isolation"])
    copro = Enum.find(registry["features"], &(&1["id"] == "copro"))

    assert protocol == %{
             "mode" => "provider_free",
             "max_tier" => "t1",
             "task" => "imp.benchmark.copro_isolation",
             "args" => ["--require-clean"],
             "manifest" => "benchmarks/config/copro-isolation-differential-v1.json",
             "artifact_validator" => %{
               "mode" => "module",
               "module" => "Elixir.Imp.BenchmarkTruth.ReproductionArtifactValidator",
               "function" => "validate!",
               "arity" => 2
             }
           }

    assert "copro_isolation" in copro["protocol_ids"]

    assert copro["admitted_evidence"] == %{
             "tier" => "t1",
             "artifact" =>
               "benchmarks/evidence/admitted/copro_isolation/5cf88e790cdf7fd12ffd6e24396b3512d59655238854b7c6406a24caa82ab37e.json",
             "artifact_sha256" =>
               "5cf88e790cdf7fd12ffd6e24396b3512d59655238854b7c6406a24caa82ab37e",
             "protocol_id" => "copro_isolation"
           }
  end

  test "classical optimizer families have separate provider-free T1 protocols" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)

    expected = [
      {"bootstrap_few_shot", "bootstrap_few_shot_differential",
       "imp.benchmark.bootstrap_few_shot_differential"},
      {"bootstrap_random_search", "random_search_differential",
       "imp.benchmark.random_search_differential"}
    ]

    Enum.each(expected, fn {feature_id, protocol_id, task} ->
      feature = Enum.find(registry["features"], &(&1["id"] == feature_id))
      protocol = get_in(registry, ["protocols", protocol_id])
      assert protocol["mode"] == "provider_free"
      assert protocol["max_tier"] == "t1"
      assert protocol["task"] == task
      assert protocol["args"] == ["--require-clean"]
      assert protocol["manifest"] == "benchmarks/config/classical-optimizer-differential-v1.json"
      assert protocol_id in feature["protocol_ids"]

      evidence = feature["admitted_evidence"]
      assert evidence["tier"] == "t1"
      assert evidence["protocol_id"] == protocol_id
      assert evidence["artifact_sha256"] =~ ~r/^[0-9a-f]{64}$/

      assert evidence["artifact"] ==
               ReproductionRegistry.admitted_path(protocol_id, evidence["artifact_sha256"])
    end)
  end

  test "weight and composition reproductions own six independent authority families" do
    registry = ReproductionRegistry.load!(@registry, authority_path: @authorities)
    features = Map.new(registry["features"], &{&1["id"], &1})

    assert %{
             "avatar" => "family.optimizer_avatar_actor",
             "avatar_optimizer" => "family.optimizer_avatar_optimizer",
             "bootstrap_finetune" => "family.optimizer_bootstrap_finetune",
             "grpo" => "family.optimizer_mmgrpo",
             "better_together" => "family.optimizer_better_together",
             "ensemble" => "family.optimizer_ensemble"
           } ==
             Map.new(
               ~w(avatar avatar_optimizer bootstrap_finetune grpo better_together ensemble),
               &{&1, features[&1]["authority_family"]}
             )

    bootstrap = features["bootstrap_finetune"]["admitted_evidence"]

    assert bootstrap["artifact"] ==
             "benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json"

    assert bootstrap["artifact_sha256"] ==
             "7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d"

    assert [bootstrap_c1] = features["bootstrap_finetune"]["supporting_evidence"]
    assert bootstrap_c1["tier"] == "t1"
    assert bootstrap_c1["protocol_id"] == "bootstrap_finetune_differential"

    assert bootstrap_c1["artifact_sha256"] ==
             "8a226901c3fc2f02f005a2d6bd3057a80d73ae230205cf13f0ecf1617084ae9d"

    expected_admissions = %{
      "avatar" =>
        {"avatar_actor_differential",
         "190b4002bcb3c96f7a0a3bcea442bb58f2999a935bb2c1b0f1e64c37911beb77"},
      "avatar_optimizer" =>
        {"avatar_optimizer_differential",
         "78d9bfef98f9469aec0c9274cdd7a457182f5f909afb8dbb4a944eeb9e9fb317"},
      "grpo" =>
        {"mmgrpo_differential",
         "7c54695dcbbd4b6606a3da1d51afad858e663df5e2442adfef2c68f9ed724b51"},
      "better_together" =>
        {"better_together_differential",
         "0a41f1cfd445c75a60dc930d5242c8bd4dd708dbc2b61e6ede7a8a843a1870c9"},
      "ensemble" =>
        {"ensemble_differential",
         "3a7d990af2dd277371e33f81d53d5640dfa50beac6b843a2511cfe24ac5a61e1"}
    }

    Enum.each(expected_admissions, fn {id, {protocol_id, sha256}} ->
      evidence = features[id]["admitted_evidence"]
      assert evidence["tier"] == "t1"
      assert evidence["protocol_id"] == protocol_id
      assert evidence["artifact_sha256"] == sha256
      assert evidence["artifact"] == ReproductionRegistry.admitted_path(protocol_id, sha256)
    end)

    expected_protocols = [
      {"avatar", "avatar_actor_differential", "imp.benchmark.avatar_actor_differential",
       "benchmarks/config/avatar-actor-differential-v1.json"},
      {"avatar_optimizer", "avatar_optimizer_differential",
       "imp.benchmark.avatar_optimizer_differential",
       "benchmarks/config/avatar-optimizer-differential-v1.json"},
      {"bootstrap_finetune", "bootstrap_finetune_differential",
       "imp.benchmark.bootstrap_finetune_differential",
       "benchmarks/config/weight-composition-differential-v1.json"},
      {"better_together", "better_together_differential",
       "imp.benchmark.better_together_differential",
       "benchmarks/config/weight-composition-differential-v1.json"},
      {"ensemble", "ensemble_differential", "imp.benchmark.ensemble_differential",
       "benchmarks/config/ensemble-differential-v1.json"},
      {"grpo", "mmgrpo_differential", "imp.benchmark.mmgrpo_differential",
       "benchmarks/config/mmgrpo-differential-v1.json"}
    ]

    Enum.each(expected_protocols, fn {feature_id, protocol_id, task, manifest} ->
      protocol = get_in(registry, ["protocols", protocol_id])
      assert protocol["mode"] == "provider_free"
      assert protocol["max_tier"] == "t1"
      assert protocol["task"] == task
      assert protocol["args"] == ["--require-clean"]
      assert protocol["manifest"] == manifest
      assert protocol_id in features[feature_id]["protocol_ids"]
      assert protocol["artifact_validator"]["function"] == "validate!"
    end)
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

    assert_raise ArgumentError, ~r/must use its content-addressed path/, fn ->
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

  test "allows validators before first admission and validates their module contract" do
    registry = read_json!(@registry)
    authorities = read_json!(@authorities)

    validator = %{
      "mode" => "module",
      "module" => "Elixir.Imp.BenchmarkTruth.ReproductionArtifactValidator",
      "function" => "validate!",
      "arity" => 2
    }

    valid =
      put_in(registry, ["protocols", "package_gate", "artifact_validator"], validator)

    assert ReproductionRegistry.validate!(valid, authorities, File.cwd!()) == valid

    malformed =
      put_in(registry, ["protocols", "package_gate", "artifact_validator"], %{
        validator
        | "arity" => 1
      })

    assert_raise ArgumentError, ~r/must declare a pure module artifact validator/, fn ->
      ReproductionRegistry.validate!(malformed, authorities, File.cwd!())
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

    protocol_id =
      get_in(registry, ["features", Access.at(feature_index), "admitted_evidence", "protocol_id"])

    bytes = Jason.encode!(artifact, pretty: true)

    forged_path =
      Path.join([
        "benchmarks/evidence/admitted",
        protocol_id,
        sha256(bytes) <> ".json"
      ])

    on_exit(fn -> File.rm!(forged_path) end)
    File.mkdir_p!(Path.dirname(forged_path))
    File.write!(forged_path, bytes)

    forged =
      registry
      |> put_in(
        ["features", Access.at(feature_index), "admitted_evidence", "artifact"],
        forged_path
      )
      |> put_in(
        ["features", Access.at(feature_index), "admitted_evidence", "artifact_sha256"],
        sha256(bytes)
      )

    assert_raise ArgumentError, ~r/admitted artifact failed protocol/, fn ->
      ReproductionRegistry.validate!(forged, authorities, File.cwd!())
    end
  end

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
