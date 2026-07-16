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

  test "the provider-free overhead ceiling is informational, not a performance claim" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.runtime.provider_free_overhead_guard"))

    assert claim["gate_policy"] == "informational"
    assert claim["target_rung"] == "C2"

    assert claim["statement"] =~
             "without presenting the configured ceiling as a performance claim"
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
    assert claim["statement"] =~ "does not claim live provider training"
  end

  test "RLM research claim names unavailable exact authorities" do
    claim =
      Enum.find(read_claims!(), &(&1["id"] == "claim.rlm.provider_free_benchmark"))

    assert claim["release"] == "telos"
    assert Enum.any?(claim["limitations"], &String.contains?(&1, "S-NIAH"))
    assert Enum.any?(claim["limitations"], &String.contains?(&1, "ACQUIRE_AND_PIN_SHA256"))
    assert claim["statement"] =~ "exact paper authority"
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
