defmodule ClaimsInventoryTest do
  use ExUnit.Case, async: true

  @claims_path "benchmarks/claims.json"
  @claim_states ["asserted", "target", "retired"]
  @gate_policies ["blocking", "informational"]
  @known_lanes ~w(
    auto_evaluation_contract
    avatar_actor_differential
    avatar_optimizer_differential
    better_together_differential
    bootstrap_few_shot_differential
    bootstrap_finetune_differential
    copro_isolation
    ensemble_differential
    failure_recovery
    gepa_replication
    golden_trace
    live_matched_model
    live_provider_smoke
    livebook_execute
    local_mlx_weight_training
    optimize_anything
    optimizer_lift
    product_package
    protocol_gates
    provider_free_overhead
    rag_tool_agent
    random_search_differential
    mmgrpo_differential
    rlm_benchmark
  )

  test "claim ids, states, and gate policies are explicit and internally consistent" do
    claims = read_claims!()
    ids = Enum.map(claims, &Map.fetch!(&1, "id"))

    assert length(ids) == length(Enum.uniq(ids))

    Enum.each(claims, fn claim ->
      assert claim["claim_state"] in @claim_states,
             "#{claim["id"]} has invalid claim state #{inspect(claim["claim_state"])}"

      assert claim["gate_policy"] in @gate_policies,
             "#{claim["id"]} has invalid gate policy #{inspect(claim["gate_policy"])}"

      assert claim["target_rung"] in ~w(C0 C1 C2 C3 C4 C5),
             "#{claim["id"]} has invalid target rung #{inspect(claim["target_rung"])}"

      assert is_binary(claim["release"]) and claim["release"] != "",
             "#{claim["id"]} must name its release scope"

      assert is_binary(claim["scope"]) and claim["scope"] != "",
             "#{claim["id"]} must define a precise scope"
    end)
  end

  test "product assertions and telos targets have explicit profile policy" do
    Enum.each(read_claims!(), fn claim ->
      case claim["claim_state"] do
        "asserted" ->
          assert claim["release"] == "v0.1"
          assert claim["gate_policy"] in ~w(blocking informational)

        "target" ->
          assert claim["release"] == "telos"
          assert claim["gate_policy"] == "blocking"

          assert is_list(claim["limitations"]) and claim["limitations"] != [],
                 "#{claim["id"]} target must state its limitations"

        "retired" ->
          :ok
      end
    end)
  end

  test "the provider-free overhead budgets are informational, not a speed claim" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.runtime.provider_free_overhead_guard"))

    assert claim["gate_policy"] == "informational"
    assert claim["target_rung"] == "C2"

    assert claim["statement"] =~
             "without presenting any budget or ratio as a speed claim"
  end

  test "every claim has an evidence requirement and auditable source" do
    Enum.each(read_claims!(), fn claim ->
      assert is_list(claim["requirements"]) and claim["requirements"] != [],
             "#{claim["id"]} must name evidence requirements"

      assert Enum.all?(claim["requirements"], fn requirement ->
               is_binary(requirement["id"]) and is_binary(requirement["lane"]) and
                 requirement["evidence"] in ["full", "passing"]
             end)

      assert is_list(claim["sources"]) and claim["sources"] != [],
             "#{claim["id"]} must cite its implementation or documentation sources"
    end)
  end

  test "requirement ids are unique and every requirement names a known lane" do
    requirements = Enum.flat_map(read_claims!(), & &1["requirements"])
    ids = Enum.map(requirements, & &1["id"])

    assert length(ids) == length(Enum.uniq(ids))

    Enum.each(requirements, fn requirement ->
      assert requirement["lane"] in @known_lanes,
             "#{requirement["id"]} names unknown lane #{inspect(requirement["lane"])}"
    end)
  end

  test "live failure recovery remains an explicit full-evidence telos gap" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.failure_recovery.live"))

    assert claim["claim_state"] == "target"
    assert claim["release"] == "telos"
    assert claim["gate_policy"] == "blocking"

    assert [
             %{
               "id" => "provider_retry_timeout_idempotency_live",
               "lane" => "failure_recovery",
               "evidence" => "full"
             },
             %{
               "id" => "retrieval_and_tool_agent_recovery_live",
               "lane" => "failure_recovery",
               "evidence" => "full"
             }
           ] = claim["requirements"]

    refute "training_protocol" in claim["surface"]
    assert claim["statement"] =~ "does not claim"
    assert claim["statement"] =~ "live provider training"
  end

  test "RLM research claim names unavailable exact authorities" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.rlm.provider_free_benchmark"))

    assert claim["release"] == "telos"
    assert Enum.any?(claim["limitations"], &String.contains?(&1, "S-NIAH"))
    assert Enum.any?(claim["limitations"], &String.contains?(&1, "ACQUIRE_AND_PIN_SHA256"))
    assert claim["statement"] =~ "exact paper authority"
  end

  test "RAG, tool, agent, BFCL, and failure claims stay separated by capacity and rung" do
    claims = Map.new(read_claims!(), &{&1["id"], &1})

    capacity_claims = ~w(
      rag.provider_free_contract
      react.provider_free_tool_contract
      react_v2.provider_free_recovery_contract
      mcp.in_process_import_contract
      agents.policy_denial_contract
      code_act.provider_free_execution_contract
      program_of_thought.safe_eval_contract
      streaming.incremental_field_contract
      async.ordered_stream_contract
      persistence.credential_redaction_contract
    )

    for id <- capacity_claims do
      claim = claims["claim.#{id}"]
      assert claim["claim_state"] == "asserted"
      assert claim["target_rung"] == "C1"
      assert [%{"evidence" => "passing", "lane" => "rag_tool_agent"}] = claim["requirements"]
    end

    refute Map.has_key?(claims, "claim.rag_tools_agents.provider_free_operational")

    assert claims["claim.rag.hotpot_retrieval.differential"]["target_rung"] == "C1"
    assert claims["claim.rag.hotpot_retrieval.effectiveness"]["target_rung"] == "C3"
    assert claims["claim.tools.bfcl_scorer.conformance"]["target_rung"] == "C1"
    assert claims["claim.tools.bfcl_selection.effectiveness"]["target_rung"] == "C3"
    assert claims["claim.agents.failure_injected.runtime_differential"]["target_rung"] == "C2"
    assert claims["claim.agents.failure_recovery.effectiveness"]["target_rung"] == "C3"

    assert claims["claim.tools.bfcl_scorer.conformance"]["limitations"] |> hd() =~
             "No official BFCL"

    assert claims["claim.agents.failure_injected.runtime_differential"]["limitations"]
           |> hd() =~ "actions are held constant"
  end

  test "optimizer claims are family-specific and separate semantics from effectiveness" do
    claims = Map.new(read_claims!(), &{&1["id"], &1})

    for family <- ~w(bootstrap_few_shot random_search) do
      semantic = claims["claim.optimizer.#{family}.semantic_conformance"]
      effectiveness = claims["claim.optimizer.#{family}.effectiveness"]
      assert semantic["claim_state"] == "asserted"
      assert semantic["target_rung"] == "C1"
      assert semantic["claim_type"] == "conformance"
      assert effectiveness["target_rung"] == "C3"
      assert effectiveness["claim_type"] == "functional_effectiveness"
    end

    bootstrap = claims["claim.optimizer.bootstrap_few_shot.semantic_conformance"]
    random = claims["claim.optimizer.random_search.semantic_conformance"]

    assert get_in(bootstrap, ["requirements", Access.at(0), "lane"]) ==
             "bootstrap_few_shot_differential"

    assert get_in(random, ["requirements", Access.at(0), "lane"]) ==
             "random_search_differential"

    assert Enum.any?(bootstrap["sources"], &String.contains?(&1, "9b89dac9"))
    assert Enum.any?(random["sources"], &String.contains?(&1, "f7e49685"))

    copro = claims["claim.optimizer.copro.semantic_conformance"]
    assert copro["claim_state"] == "asserted"
    assert copro["target_rung"] == "C1"
    assert Enum.any?(copro["sources"], &String.contains?(&1, "5cf88e79"))
    assert get_in(copro, ["requirements", Access.at(0), "lane"]) == "copro_isolation"
    assert hd(copro["limitations"]) =~ "exact Python RNG parity"

    refute Map.has_key?(claims, "claim.optimizer_lift.full")
  end

  test "weight families have independent C0, C1, and C3 obligations" do
    claims = Map.new(read_claims!(), &{&1["id"], &1})

    families = %{
      "avatar_actor" => {["Avatar"], "avatar_actor_differential"},
      "avatar_optimizer" => {["AvatarOptimizer"], "avatar_optimizer_differential"},
      "bootstrap_finetune" => {["BootstrapFinetune"], "bootstrap_finetune_differential"},
      "mmgrpo" => {["GRPO", "mmGRPO"], "mmgrpo_differential"},
      "better_together" => {["BetterTogether"], "better_together_differential"},
      "ensemble" => {["Ensemble"], "ensemble_differential"}
    }

    Enum.each(families, fn {family, {surfaces, lane}} ->
      api = claims["claim.optimizer.#{family}.api"]
      semantic = claims["claim.optimizer.#{family}.semantic_conformance"]

      assert api["claim_state"] == "asserted"
      assert api["target_rung"] == "C0"
      assert api["claim_type"] == "feature_completeness"
      assert get_in(api, ["requirements", Access.at(0), "lane"]) == "product_package"

      assert semantic["claim_state"] == "asserted"
      assert semantic["target_rung"] == "C1"
      assert semantic["claim_type"] == "conformance"
      assert semantic["gate_policy"] == "informational"
      assert get_in(semantic, ["requirements", Access.at(0), "lane"]) == lane
      assert MapSet.subset?(MapSet.new(surfaces), MapSet.new(api["surface"]))
      assert MapSet.subset?(MapSet.new(surfaces), MapSet.new(semantic["surface"]))
    end)

    assert claims["claim.optimizer.avatar_actor.effectiveness"]["surface"] == ["Avatar"]

    assert claims["claim.optimizer.avatar_optimizer.effectiveness"]["surface"] == [
             "AvatarOptimizer"
           ]

    refute Map.has_key?(claims, "claim.optimizer.avatar.effectiveness")

    c3_ids = ~w(
      claim.optimizer.avatar_actor.effectiveness
      claim.optimizer.avatar_optimizer.effectiveness
      claim.optimizer.bootstrap_finetune.provider_effectiveness
      claim.optimizer.mmgrpo.effectiveness
      claim.optimizer.better_together.effectiveness
      claim.optimizer.ensemble.effectiveness
    )

    for id <- c3_ids do
      assert claims[id]["target_rung"] == "C3"
    end
  end

  test "OA bounded effectiveness and evaluation quality gaps remain explicit" do
    claims = Map.new(read_claims!(), &{&1["id"], &1})
    oa = claims["claim.optimize_anything.non_prompt_effectiveness"]

    assert oa["claim_state"] == "asserted"
    assert oa["release"] == "v0.1"
    assert Enum.any?(oa["limitations"], &String.contains?(&1, "bounded to three"))
    assert oa["statement"] =~ "improved all three"
    assert Enum.any?(oa["sources"], &String.contains?(&1, "58ff84ac"))

    assert claims["claim.optimize_anything.upstream_comparative_effectiveness"]["claim_state"] ==
             "target"

    auto_evaluation = claims["claim.evaluation.auto_evaluation.semantic_conformance"]
    assert auto_evaluation["claim_state"] == "asserted"
    assert auto_evaluation["target_rung"] == "C1"

    assert get_in(auto_evaluation, ["requirements", Access.at(0), "lane"]) ==
             "auto_evaluation_contract"

    assert claims["claim.evaluation.natural_judge.effectiveness"]["target_rung"] == "C3"
    assert claims["claim.evaluation.refine_advice.effectiveness"]["target_rung"] == "C3"

    assert get_in(claims, [
             "claim.evaluation.natural_judge.effectiveness",
             "requirements",
             Access.at(0),
             "lane"
           ]) == "live_matched_model"

    assert get_in(claims, [
             "claim.evaluation.refine_advice.effectiveness",
             "requirements",
             Access.at(0),
             "lane"
           ]) == "live_matched_model"
  end

  test "local MLX effectiveness claim remains narrow and independently gated" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.local_mlx_weight_training.effectiveness"))

    assert claim["claim_state"] == "asserted"
    assert claim["comparison"] == "imp_local_baseline"
    assert claim["limitations"] != []

    assert [%{"lane" => "local_mlx_weight_training", "evidence" => "full"}] =
             claim["requirements"]

    refute "BetterTogether" in claim["surface"]
    refute "GRPO" in claim["surface"]
  end

  test "every claim source resolves to a real file, directory, or glob in the repo" do
    Enum.each(read_claims!(), fn claim ->
      Enum.each(claim["sources"], fn source ->
        assert File.exists?(source) or Path.wildcard(source) != [],
               "#{claim["id"]} cites source #{inspect(source)} which does not exist; " <>
                 "a claim whose evidence file disappears must fail loudly"
      end)
    end)
  end

  defp read_claims! do
    inventory = @claims_path |> File.read!() |> Jason.decode!()
    assert inventory["schema_version"] == 2
    Map.fetch!(inventory, "claims")
  end
end
