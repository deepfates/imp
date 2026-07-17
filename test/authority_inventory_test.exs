defmodule AuthorityInventoryTest do
  use ExUnit.Case, async: true

  @authority_path "benchmarks/authorities.json"
  @claims_path "benchmarks/claims.json"
  @surface_map_path "docs/UPSTREAM_SURFACE_MAP.md"
  @coverage_matrix_path "docs/COVERAGE_MATRIX.md"
  @parity_program_path "docs/PARITY_VALIDATION_PROGRAM.md"

  @dimensions [
    "upstream_repository",
    "primary_authority",
    "upstream_tests",
    "dataset_protocol",
    "local_differential"
  ]

  @accepted_statuses %{
    "upstream_repository" => [
      "release_and_commit_pinned",
      "commit_pinned",
      "gap",
      "not_applicable"
    ],
    "primary_authority" => [
      "pinned",
      "identified",
      "no_primary_authority",
      "gap",
      "not_applicable"
    ],
    "upstream_tests" => ["present", "partial", "absent", "not_audited", "not_applicable"],
    "dataset_protocol" => ["pinned", "protocol_defined", "partial", "gap", "not_applicable"],
    "local_differential" => ["present", "partial", "gap", "not_applicable"]
  }

  test "ledger schema is explicit and every family has all authority dimensions" do
    ledger = read_json!(@authority_path)

    assert ledger["schema_version"] == 1
    assert is_binary(ledger["purpose"]) and ledger["purpose"] != ""
    assert is_list(ledger["generated_from"])
    assert ledger["status_vocabulary"] == @accepted_statuses
    assert is_list(ledger["families"]) and ledger["families"] != []

    Enum.each(ledger["families"], fn family ->
      assert is_binary(family["id"]) and String.starts_with?(family["id"], "family.")
      assert is_binary(family["name"]) and family["name"] != ""

      assert family["kind"] in [
               "algorithm",
               "benchmark",
               "operations",
               "optimizer",
               "product",
               "runtime"
             ]

      for mapping <- [
            "surface_tokens",
            "upstream_surface_ids",
            "coverage_matrix_concepts",
            "parity_lanes"
          ] do
        assert is_list(family[mapping]), "#{family["id"]} must include #{mapping}"
        assert Enum.all?(family[mapping], &is_binary/1)
      end

      for dimension <- @dimensions do
        assert is_map(family[dimension]), "#{family["id"]} must include #{dimension}"
      end

      assert_keys(family["upstream_repository"], [
        "status",
        "repository",
        "version",
        "git_ref",
        "commit",
        "source_paths",
        "source_manifest"
      ])

      assert_keys(family["primary_authority"], ["status", "locator", "revision", "title"])
      assert_keys(family["upstream_tests"], ["status", "references"])
      assert_keys(family["dataset_protocol"], ["status", "references", "immutable_digests"])
      assert_keys(family["local_differential"], ["status", "artifacts"])
    end)
  end

  test "family ids are unique and statuses use the declared vocabulary" do
    ledger = read_json!(@authority_path)
    ids = Enum.map(ledger["families"], &Map.fetch!(&1, "id"))

    assert ids == Enum.uniq(ids)

    Enum.each(ledger["families"], fn family ->
      for dimension <- @dimensions do
        status = family[dimension]["status"]

        assert status in @accepted_statuses[dimension],
               "#{family["id"]} has invalid #{dimension} status #{inspect(status)}"
      end

      repository = family["upstream_repository"]

      if repository["status"] in ["release_and_commit_pinned", "commit_pinned"] do
        assert is_binary(repository["repository"]) and repository["repository"] != ""
        assert is_binary(repository["version"]) and repository["version"] != ""
        assert is_binary(repository["git_ref"]) and repository["git_ref"] != ""
        assert repository["commit"] =~ ~r/^[0-9a-f]{40}$/
      end
    end)
  end

  test "DSPy 3.3.0b1 instruction optimizer hashes match the audited source pins" do
    pins = read_json!(@authority_path)["pinned_sources"]["dspy_instruction_optimizers"]

    assert pins["version"] == "3.3.0b1"
    assert pins["commit"] == "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"

    assert Map.new(pins["files"], &{&1["path"], &1["sha256"]}) == %{
             "dspy/propose/grounded_proposer.py" =>
               "c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3",
             "dspy/teleprompt/bootstrap.py" =>
               "0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255",
             "dspy/teleprompt/mipro_optimizer_v2.py" =>
               "6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3",
             "dspy/teleprompt/simba.py" =>
               "4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55",
             "dspy/teleprompt/simba_utils.py" =>
               "ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c",
             "dspy/teleprompt/utils.py" =>
               "218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182"
           }
  end

  test "GEPA authority and independent implementation comparators are immutable" do
    pins = read_json!(@authority_path)["pinned_sources"]

    assert pins["gepa_standalone"] == %{
             "role" => "algorithm_authority",
             "repository" => "https://github.com/gepa-ai/gepa",
             "version" => "0.1.4",
             "git_ref" => "refs/tags/v0.1.4",
             "commit" => "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975",
             "paper" => "https://arxiv.org/abs/2507.19457v2"
           }

    historical = pins["gepa_v0_1_1_contract"]

    assert Map.take(historical, ~w(role repository version git_ref commit paper)) == %{
             "role" => "historical_executable_contract",
             "repository" => "https://github.com/gepa-ai/gepa",
             "version" => "0.1.1",
             "git_ref" => "refs/tags/v0.1.1",
             "commit" => "b4dbb55b7601dac448cdb836d5a401ca7d9eb920",
             "paper" => "https://arxiv.org/abs/2507.19457v2"
           }

    assert historical["metadata"] == %{"project_version" => "0.1.0"}
    assert map_size(historical["source_hashes"]) == 7

    assert Enum.all?(historical["source_hashes"], fn {_path, hash} ->
             hash =~ ~r/^[0-9a-f]{64}$/
           end)

    assert pins["ax_typescript"]["role"] == "independent_implementation_comparator"
    assert pins["ax_typescript"]["commit"] == "eb5835e54ba0c5b2fbac380daed1cb87faeefd5e"
    assert pins["ax_typescript"]["source_manifest"]["file_count"] == 11
    assert length(pins["ax_typescript"]["source_paths"]) == 11
    assert pins["req_llm"]["role"] == "beam_runtime_dependency"
    assert pins["req_llm"]["commit"] == "33840077c2f1332eb6dff2d268dff02393014da4"
  end

  test "mmGRPO implementation authority is DSPy source and DeepSeekMath is background only" do
    family =
      read_json!(@authority_path)["families"]
      |> Enum.find(&(&1["id"] == "family.optimizer_mmgrpo"))

    assert family["primary_authority"] == %{
             "status" => "pinned",
             "locator" =>
               "https://github.com/stanfordnlp/dspy/blob/29448ae12756abdd14bd8796c819247ebb83673c/dspy/teleprompt/grpo.py",
             "revision" => "29448ae12756abdd14bd8796c819247ebb83673c",
             "title" => "DSPy 3.2.1 mmGRPO"
           }

    deepseek = hd(family["background_authorities"])
    assert deepseek["surface"] =~ "background only"
    assert deepseek["surface"] =~ "not the Imp implementation authority"
  end

  test "every claim inventory surface token is explicitly owned by a family" do
    ledger = read_json!(@authority_path)
    claims = read_json!(@claims_path)["claims"]

    claimed_tokens = claims |> Enum.flat_map(& &1["surface"]) |> MapSet.new()
    mapped_tokens = ledger["families"] |> Enum.flat_map(& &1["surface_tokens"]) |> MapSet.new()

    assert MapSet.difference(claimed_tokens, mapped_tokens) == MapSet.new()
  end

  test "weight families have separate authorities and only Imp BootstrapFinetune owns local evidence" do
    families = Map.new(read_json!(@authority_path)["families"], &{&1["id"], &1})

    expected = %{
      "family.optimizer_avatar_actor" =>
        {"dspy/predict/avatar/avatar.py",
         "9b41efb8837de2bfe85914e7b5dc0117ef56570cb5dcb816b032aa205016f0bf"},
      "family.optimizer_avatar_optimizer" =>
        {"dspy/teleprompt/avatar_optimizer.py",
         "628eefedcdcdbc296bab0256ec8e3ed932e91fd75f1f8d56081cee5a40abe5ae"},
      "family.optimizer_bootstrap_finetune" =>
        {"dspy/teleprompt/bootstrap_finetune.py",
         "d3d3411e8f00d36fc7967290753af66bbe31b01038363e8685427cc58af5963f"},
      "family.optimizer_mmgrpo" =>
        {"dspy/teleprompt/grpo.py",
         "da7f570df12bafc46ab9dc68b1e99cf2e233a30b7c08bd35e284b9c8738b96df"},
      "family.optimizer_better_together" =>
        {"dspy/teleprompt/bettertogether.py",
         "e9ea96ed106d063e30c994dc0ebd4601fd099b9c3b91d43d92acb71e30f38334"},
      "family.optimizer_ensemble" =>
        {"dspy/teleprompt/ensemble.py",
         "f206b5891d79b11590dc3ab41a9c22e249d3fa015f3c410d801f42759ef90793"}
    }

    Enum.each(expected, fn {id, {source, hash}} ->
      family = Map.fetch!(families, id)

      assert Enum.any?(family["upstream_repository"]["source_paths"], fn path ->
               source == path or String.starts_with?(source, path <> "/")
             end)

      assert hash in family["upstream_source_hashes"]
      assert family["primary_authority"]["status"] == "pinned"
    end)

    refute Map.has_key?(families, "family.optimizer_weights")

    bootstrap = families["family.optimizer_bootstrap_finetune"]

    assert bootstrap["local_differential"]["artifacts"] == [
             "benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json"
           ]

    refute inspect(bootstrap) =~
             "c7299fa4900557388f86d37d3198b24f520f80238157c6f6a6b92511249a0d16"

    for {id, _} <- expected, id != "family.optimizer_bootstrap_finetune" do
      assert families[id]["local_differential"] == %{"status" => "gap", "artifacts" => []}
    end
  end

  test "every upstream map row, coverage concept, and parity lane is mapped" do
    families = read_json!(@authority_path)["families"]

    assert_all_mapped(
      upstream_surface_ids(File.read!(@surface_map_path)),
      Enum.flat_map(families, & &1["upstream_surface_ids"]),
      "upstream surface"
    )

    assert_all_mapped(
      coverage_concepts(File.read!(@coverage_matrix_path)),
      Enum.flat_map(families, & &1["coverage_matrix_concepts"]),
      "coverage concept"
    )

    assert_all_mapped(
      parity_lanes(File.read!(@parity_program_path)),
      Enum.flat_map(families, & &1["parity_lanes"]),
      "parity lane"
    )
  end

  defp upstream_surface_ids(body) do
    Regex.scan(~r/^\| ([a-z][a-z0-9_.]+) \|/m, body, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp coverage_concepts(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(fn row -> row |> String.split("|") |> Enum.at(1) |> String.trim() end)
    |> Enum.reject(&(&1 in ["", "---", "Concept", "Upstream concept"]))
    |> MapSet.new()
  end

  defp parity_lanes(body) do
    Regex.scan(~r/^## (Lane \d+: .+)$/m, body, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp assert_all_mapped(expected, mapped, label) do
    missing = MapSet.difference(expected, MapSet.new(mapped))
    assert missing == MapSet.new(), "unmapped #{label}s: #{inspect(MapSet.to_list(missing))}"
  end

  defp assert_keys(map, keys) do
    Enum.each(keys, fn key ->
      assert Map.has_key?(map, key), "missing required key #{key}"
    end)
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
