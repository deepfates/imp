defmodule ClaimsInventoryTest do
  use ExUnit.Case, async: true

  @claims_path "benchmarks/claims.json"
  @claim_states ["asserted", "target", "retired"]
  @gate_policies ["blocking", "informational"]
  @known_lanes ~w(
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

  test "RAG, BFCL, and failure claims stay separated by authority and rung" do
    operational =
      Enum.find(
        read_claims!(),
        &(&1["id"] == "claim.rag_tools_agents.provider_free_operational")
      )

    assert operational["claim_state"] == "asserted"
    assert operational["target_rung"] == "C2"
    assert [%{"evidence" => "passing"}] = operational["requirements"]
    assert hd(operational["limitations"]) =~ "does not establish HotPotQA"

    claims = Map.new(read_claims!(), &{&1["id"], &1})

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
      assert semantic["target_rung"] == "C1"
      assert semantic["claim_type"] == "conformance"
      assert effectiveness["target_rung"] == "C3"
      assert effectiveness["claim_type"] == "functional_effectiveness"
    end

    copro = claims["claim.optimizer.copro.semantic_conformance"]
    assert copro["claim_state"] == "asserted"
    assert copro["target_rung"] == "C1"
    assert copro["sources"] |> Enum.any?(&String.contains?(&1, "dcad73d7"))
    assert hd(copro["limitations"]) =~ "excludes exact Python RNG parity"

    refute Map.has_key?(claims, "claim.optimizer_lift.full")
  end

  test "OA failure and evaluation quality gaps remain explicit" do
    claims = Map.new(read_claims!(), &{&1["id"], &1})
    oa = claims["claim.optimize_anything.non_prompt_effectiveness"]

    assert oa["claim_state"] == "asserted"
    assert oa["release"] == "v0.1"
    assert Enum.any?(oa["limitations"], &String.contains?(&1, "produced no admissible artifact"))
    assert oa["statement"] =~ "current evidence does not establish"

    assert claims["claim.optimize_anything.upstream_comparative_effectiveness"]["claim_state"] ==
             "target"

    assert claims["claim.evaluation.auto_evaluation.semantic_conformance"]["target_rung"] ==
             "C1"

    assert claims["claim.evaluation.natural_judge.effectiveness"]["target_rung"] == "C3"
    assert claims["claim.evaluation.refine_advice.effectiveness"]["target_rung"] == "C3"
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

  defp read_claims! do
    inventory = @claims_path |> File.read!() |> Jason.decode!()
    assert inventory["schema_version"] == 2
    Map.fetch!(inventory, "claims")
  end
end
