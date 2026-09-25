defmodule PublicAPIManifestTest do
  use ExUnit.Case, async: false

  @manifest_path "priv/public_api.json"

  test "checked-in manifest exactly matches the curated packaged API" do
    expected = Mix.Tasks.Imp.PublicApi.manifest()
    actual = @manifest_path |> File.read!() |> Jason.decode!()

    assert actual == expected
    assert actual["schema_version"] == 3
    assert actual["app"] == "imp"
    assert actual["package_version"] == Mix.Project.config()[:version]
    assert actual["modules"] != []
    assert actual["excluded_modules"] != []
  end

  test "manifest is deterministic and contains no machine-local paths or timestamps" do
    first = Mix.Tasks.Imp.PublicApi.manifest()
    second = Mix.Tasks.Imp.PublicApi.manifest()
    first_encoded = Mix.Tasks.Imp.PublicApi.encoded_manifest()
    second_encoded = Mix.Tasks.Imp.PublicApi.encoded_manifest()

    assert first == second
    assert first_encoded == second_encoded
    assert Jason.decode!(first_encoded) == first
    refute Map.has_key?(first, "generated_at")
    refute first_encoded =~ File.cwd!()
    refute first_encoded =~ "tmp/"
  end

  test "plain Mix project loading does not depend on dependency modules" do
    env = [
      {"MIX_ENV", "test"},
      {"MIX_PATH", ""},
      {"ERL_LIBS", ""}
    ]

    assert {output, 0} =
             System.cmd("mix", ["help", "test"],
               cd: File.cwd!(),
               env: env,
               stderr_to_stdout: true
             )

    assert output =~ "mix test"
  end

  test "manifest records category-gated facade, SPI, struct, and type contracts" do
    modules = Map.new(Mix.Tasks.Imp.PublicApi.manifest()["modules"], &{&1["module"], &1})

    assert modules["Imp"]["category"] == "facade"
    assert "predict/2" in modules["Imp"]["functions"]
    assert "start_run/3" in modules["Imp"]["functions"]
    assert "cancel_run/3" in modules["Imp"]["functions"]
    assert "optimize/4" in modules["Imp"]["functions"]
    assert "fields" in modules["Imp.Example"]["struct_fields"]
    assert %{"kind" => "type", "name" => "t/0"} in modules["Imp.Example"]["types"]
    assert %{"name" => "call/2", "optional" => false} in modules["Imp.Module"]["callbacks"]
    assert modules["Imp.Optimizer"]["category"] == "spi"
    assert modules["Imp.Clients.ReqLLM"]["category"] == "stable"
    assert modules["Imp.Clients.TrainingJob"]["category"] == "experimental"
    assert modules["Imp.Clients.TRLTrainer"]["category"] == "experimental"

    assert %{"name" => "run/3", "optional" => false} in modules["Imp.Optimizer"][
             "callbacks"
           ]

    assert %{"name" => "generate/2", "optional" => false} in modules["Imp.LM"]["callbacks"]
    assert %{"name" => "request/5", "optional" => true} in modules["Imp.HTTP"]["callbacks"]
    assert modules["Imp.Example"]["callbacks"] == []
  end

  test "manifest records every field of every supported public struct" do
    Mix.Tasks.Imp.PublicApi.manifest()["modules"]
    |> Enum.filter(&(&1["kind"] == "struct"))
    |> Enum.each(fn entry ->
      module = module_from_string(entry["module"])

      expected =
        module.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert entry["struct_fields"] == expected,
             "incomplete public struct contract for #{entry["module"]}"
    end)
  end

  test "manifest records every callback of every supported public behaviour" do
    Mix.Tasks.Imp.PublicApi.manifest()["modules"]
    |> Enum.filter(&(&1["kind"] == "behaviour"))
    |> Enum.each(fn entry ->
      module = module_from_string(entry["module"])

      expected =
        module.behaviour_info(:callbacks)
        |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
        |> Enum.sort()

      actual = entry["callbacks"] |> Enum.map(& &1["name"]) |> Enum.sort()

      assert actual == expected,
             "incomplete public behaviour contract for #{entry["module"]}"
    end)
  end

  test "manifest omits hidden and generated runtime exports and records internal exclusions" do
    manifest = Mix.Tasks.Imp.PublicApi.manifest()
    modules = Map.new(manifest["modules"], &{&1["module"], &1})
    excluded = MapSet.new(manifest["excluded_modules"], & &1["module"])

    refute "normalize_demos!/2" in modules["Imp.Example"]["functions"]
    refute "__struct__/0" in modules["Imp.Example"]["functions"]
    refute "child_spec/1" in modules["Imp.Cache"]["functions"]
    refute "Imp.Agent" in excluded
    refute "Imp.Agent.Runtime" in excluded
    assert modules["Imp.Saving.Registry"]["category"] == "stable"
    refute "Imp.Saving.Registry" in excluded
  end

  test "manifest excludes benchmark, evidence, and Mix task control-plane modules" do
    entries = Mix.Tasks.Imp.PublicApi.manifest()["modules"]

    refute Enum.any?(entries, fn entry ->
             String.starts_with?(entry["module"], "Imp.Benchmark") or
               String.starts_with?(entry["module"], "Imp.BenchmarkTruth") or
               String.starts_with?(entry["module"], "Imp.Evidence") or
               String.starts_with?(entry["module"], "Mix.Tasks.")
           end)
  end

  test "ExDoc filters every Mix task, including non-benchmark tasks" do
    filter = Mix.Project.config()[:docs][:filter_modules]

    mix_tasks =
      :imp
      |> Application.spec(:modules)
      |> Enum.filter(fn module ->
        module |> Atom.to_string() |> String.starts_with?("Elixir.Mix.Tasks.")
      end)

    assert mix_tasks != []
    assert Enum.all?(mix_tasks, &(filter.(&1, %{}) == false))
    assert filter.(Imp, %{})
  end

  test "ExDoc filters every module classified internal by the canonical manifest" do
    filter = Mix.Project.config()[:docs][:filter_modules]

    internal_modules =
      Mix.Tasks.Imp.PublicApi.manifest()["excluded_modules"]
      |> Enum.map(&module_from_string(&1["module"]))

    assert internal_modules != []
    assert Enum.all?(internal_modules, &(filter.(&1, %{}) == false))
    assert filter.(Imp.Optimize.Anything, %{})
  end

  test "ExDoc generated module pages are exactly the supported manifest modules" do
    Application.ensure_all_started(:ex_doc)
    config = ExDoc.Config.build(Mix.Project.config()[:docs])

    {nodes, _filtered} =
      ExDoc.Retriever.docs_from_modules(Application.spec(:imp, :modules), config)

    generated = nodes |> Enum.map(&inspect(&1.module)) |> MapSet.new()
    supported = Mix.Tasks.Imp.PublicApi.manifest()["modules"] |> MapSet.new(& &1["module"])

    assert generated == supported
    # hexdocs opens on the README, the front door the documentation contract tests guard.
    assert Mix.Project.config()[:docs][:main] == "readme"
    assert MapSet.member?(generated, "Imp")
  end

  test "new documented modules under experimental namespaces require explicit classification" do
    assert_raise Mix.Error, ~r/unclassified: Imp\.Optimizer\.FutureOptimizer/, fn ->
      Mix.Tasks.Imp.PublicApi.classify_module("Imp.Optimizer.FutureOptimizer")
    end
  end

  test "ExDoc groups derive the stable center and experimental surface from the manifest" do
    manifest = Mix.Tasks.Imp.PublicApi.manifest()
    modules = Map.new(manifest["modules"], &{&1["module"], &1["category"]})
    groups = Map.new(Mix.Project.config()[:docs][:groups_for_modules])

    stable = groups["Stable center"]
    experimental = groups["Experimental optimizers and advanced workflows"]
    extension = groups["Extension interfaces"]

    assert "Imp" in stable
    assert "Imp.Signature" in stable
    assert "Imp.Optimizer.GEPA" in experimental
    assert "Imp.Optimize.Anything" in experimental
    assert "Imp.Optimizer" in extension

    assert Enum.all?(stable, &(modules[&1] in ["facade", "stable"]))
    assert Enum.all?(experimental, &(modules[&1] == "experimental"))
    assert Enum.all?(extension, &(modules[&1] == "spi"))
  end

  test "policy prefixes are module-boundary aware" do
    assert Mix.Tasks.Imp.PublicApi.classify_module("Imp.Optimizer.GEPA.Engine") == "internal"

    assert_raise Mix.Error, ~r/unclassified: Imp\.AgentFuture/, fn ->
      Mix.Tasks.Imp.PublicApi.classify_module("Imp.AgentFuture")
    end

    assert_raise Mix.Error, ~r/unclassified: Imp\.Optimizer\.GEPAFuture/, fn ->
      Mix.Tasks.Imp.PublicApi.classify_module("Imp.Optimizer.GEPAFuture")
    end
  end

  test "API diff classification is deterministic and follows pre-1.0 guidance" do
    base = snapshot()

    assert Mix.Tasks.Imp.PublicApi.api_diff(base, base)["classification"] == "no_change"

    metadata = Map.put(base, "package_version", "0.1.1")
    metadata_diff = Mix.Tasks.Imp.PublicApi.api_diff(base, metadata)
    assert metadata_diff["classification"] == "metadata_only"
    assert metadata_diff["semver"]["bump"] == "patch"
    assert metadata_diff["semver"]["recommended_version"] == "0.1.1"

    additive = Map.update!(base, "modules", &(&1 ++ [module_entry("Imp.Added")]))
    additive_diff = Mix.Tasks.Imp.PublicApi.api_diff(base, additive)
    assert additive_diff["classification"] == "additive"
    assert Enum.any?(additive_diff["additive_changes"], &(&1["type"] == "module_added"))
    assert additive_diff["semver"]["recommended_version"] == "0.1.1"

    additive_member =
      update_in(base, ["modules", Access.at(0)], fn entry ->
        entry
        |> Map.update!("functions", &(&1 ++ ["stream/1"]))
        |> put_in(["signatures", "functions", "stream/1"], ["stream(candidate)"])
      end)

    additive_member_diff = Mix.Tasks.Imp.PublicApi.api_diff(base, additive_member)
    assert additive_member_diff["classification"] == "additive"
    assert additive_member_diff["breaking_changes"] == []

    assert Enum.any?(additive_member_diff["additive_changes"], fn change ->
             change["type"] == "function_added" and change["member"] == "stream/1"
           end)

    removed_previous = Map.update!(base, "modules", &(&1 ++ [module_entry("Imp.Removed")]))
    removed_diff = Mix.Tasks.Imp.PublicApi.api_diff(removed_previous, base)
    assert removed_diff["classification"] == "breaking"
    assert Enum.any?(removed_diff["breaking_changes"], &(&1["type"] == "module_removed"))
    assert removed_diff["semver"]["recommended_version"] == "0.2.0"

    changed =
      Map.update!(base, "modules", fn [entry] ->
        [
          entry
          |> Map.put("category", "stable")
          |> Map.put("source", "lib/renamed.ex")
          |> put_in(["signatures", "functions", "run/1"], ["run(other)"])
        ]
      end)

    changed_diff = Mix.Tasks.Imp.PublicApi.api_diff(base, changed)
    assert changed_diff["classification"] == "breaking"
    assert Enum.any?(changed_diff["breaking_changes"], &(&1["type"] == "module_tier_changed"))
    assert Enum.any?(changed_diff["breaking_changes"], &(&1["type"] == "module_source_changed"))
    assert Enum.any?(changed_diff["breaking_changes"], &(&1["type"] == "signature_changed"))

    stable = Mix.Tasks.Imp.PublicApi.semver_guidance("1.2.3", "breaking")
    assert stable["recommended_version"] == "2.0.0"
    refute stable["pre_1_0"]
  end

  test "API diff accepts the supported schema 2 historical snapshot" do
    historical = snapshot(schema_version: 2)

    assert Mix.Tasks.Imp.PublicApi.api_diff(historical, historical)["classification"] ==
             "no_change"
  end

  test "API diff rejects malformed baselines with controlled Mix errors" do
    base = snapshot()

    invalid_snapshots = [
      {Map.delete(base, "schema_version"), ~r/missing required field "schema_version"/},
      {Map.delete(base, "package_version"), ~r/missing required field "package_version"/},
      {Map.delete(base, "modules"), ~r/missing required field "modules"/},
      {Map.put(base, "schema_version", "3"), ~r/schema_version must be one of 2 or 3/},
      {Map.put(base, "modules", []), ~r/modules must be a non-empty list/},
      {Map.put(base, "modules", %{}), ~r/modules must be a non-empty list/},
      {
        put_in(base, ["modules", Access.at(0), "functions"], "run/1"),
        ~r/functions must be a list/
      },
      {
        Map.update!(base, "modules", &(&1 ++ [hd(&1)])),
        ~r/modules must not contain duplicate module names/
      },
      {
        Map.put(base, "excluded_modules", [
          %{"category" => "internal", "module" => "Imp", "source" => "lib/imp.ex"}
        ]),
        ~r/module names must be unique across modules and excluded_modules/
      }
    ]

    Enum.each(invalid_snapshots, fn {invalid, message} ->
      assert_raise Mix.Error, message, fn ->
        Mix.Tasks.Imp.PublicApi.api_diff(invalid, base)
      end
    end)
  end

  test "diff CLI rejects malformed JSON and non-object baselines cleanly" do
    for contents <- ["{", "[]", Jason.encode!(%{})] do
      path = write_snapshot!(contents)

      assert_raise Mix.Error, ~r/invalid public API snapshot/, fn ->
        Mix.Tasks.Imp.PublicApi.run(["--diff", path])
      end
    end
  end

  test "diff CLI rejects an empty or wrongly typed module inventory" do
    base = snapshot()

    for invalid <- [Map.put(base, "modules", []), Map.put(base, "modules", %{})] do
      path = write_snapshot!(Jason.encode!(invalid))

      assert_raise Mix.Error,
                   ~r/invalid public API snapshot .*modules must be a non-empty list/,
                   fn ->
                     Mix.Tasks.Imp.PublicApi.run(["--diff", path])
                   end
    end
  end

  test "classification is independent of rule order" do
    policy = Jason.decode!(File.read!("priv/public_api_policy.json"))
    path = write_policy!(Map.update!(policy, "rules", &Enum.reverse/1))

    assert Mix.Tasks.Imp.PublicApi.manifest(policy: path) ==
             Mix.Tasks.Imp.PublicApi.manifest()
  end

  test "ambiguous equal-specificity classification is rejected" do
    policy = Jason.decode!(File.read!("priv/public_api_policy.json"))

    conflicting_rule = %{"category" => "stable", "modules" => ["Imp"]}
    path = write_policy!(Map.update!(policy, "rules", &(&1 ++ [conflicting_rule])))

    assert_raise Mix.Error, ~r/ambiguous most_specific_match overlap for Imp/, fn ->
      Mix.Tasks.Imp.PublicApi.manifest(policy: path)
    end
  end

  test "owned shipped docs do not present excluded modules as supported" do
    excluded =
      Mix.Tasks.Imp.PublicApi.manifest()["excluded_modules"]
      |> Enum.map(& &1["module"])
      |> MapSet.new()

    references =
      [
        "README.md",
        "docs/PRODUCTION_OPERATIONS.md",
        "docs/LEARNING_PATH.md",
        "docs/coming-from-dspy.md",
        "livebooks/03_evaluate_and_optimize.livemd"
      ]
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(&Regex.scan(~r/Imp(?:\.[A-Z][A-Za-z0-9_]*)+/, &1))
        |> List.flatten()
      end)
      |> MapSet.new()

    assert MapSet.disjoint?(excluded, references)
  end

  test "policy fails closed for an unclassified documented package module" do
    policy = Jason.decode!(File.read!("priv/public_api_policy.json"))

    rules =
      Enum.map(policy["rules"], fn
        %{"category" => "facade"} = rule -> Map.put(rule, "modules", [])
        rule -> rule
      end)

    path = write_policy!(Map.put(policy, "rules", rules))

    assert_raise Mix.Error, ~r/unclassified: Imp$/, fn ->
      Mix.Tasks.Imp.PublicApi.manifest(policy: path)
    end
  end

  test "policy fails closed for a missing documented export" do
    policy = Jason.decode!(File.read!("priv/public_api_policy.json"))
    path = write_policy!(put_in(policy, ["export_exclusions", "Imp"], ["missing/0"]))

    assert_raise Mix.Error, ~r/missing documented export missing\/0 on Imp/, fn ->
      Mix.Tasks.Imp.PublicApi.manifest(policy: path)
    end
  end

  defp write_policy!(policy) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-public-api-policy-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(policy))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_snapshot!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-public-api-snapshot-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp module_from_string(name) do
    name
    |> String.split(".")
    |> Module.concat()
  end

  defp snapshot(opts \\ []) do
    schema_version = Keyword.get(opts, :schema_version, 3)

    snapshot = %{
      "schema_version" => schema_version,
      "app" => "imp",
      "package_version" => "0.1.0",
      "scope" => "scope",
      "categories" => [
        %{
          "name" => "facade",
          "callbacks" => false,
          "types" => false,
          "support" => "facade"
        },
        %{"name" => "stable", "callbacks" => false, "types" => true, "support" => "stable"},
        %{"name" => "internal", "callbacks" => false, "types" => false, "support" => "excluded"}
      ],
      "excluded_modules" => [],
      "modules" => [module_entry("Imp")]
    }

    if schema_version == 2 do
      snapshot
      |> update_in(
        ["categories"],
        &Enum.map(&1, fn category -> Map.delete(category, "support") end)
      )
      |> update_in(["modules", Access.at(0)], &Map.delete(&1, "signatures"))
    else
      snapshot
    end
  end

  defp module_entry(module) do
    %{
      "module" => module,
      "source" => "lib/imp.ex",
      "category" => "facade",
      "kind" => "module",
      "functions" => ["run/1"],
      "macros" => [],
      "signatures" => %{"functions" => %{"run/1" => ["run(candidate)"]}},
      "callbacks" => [],
      "types" => [],
      "struct_fields" => []
    }
  end
end
