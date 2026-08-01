alias Imp.BenchmarkTruth.HoverGepaNoMergePlan

if System.get_env("LIVE_PROVIDER") == "1" do
  raise "HoVer planner checkpoint is provider-disabled; live execution is not authorized"
end

:ok = HoverGepaNoMergePlan.verify_authorities!()
plan = HoverGepaNoMergePlan.design()

output_root =
  case System.argv() do
    ["--output-root", root] -> Path.expand(root)
    other -> raise "expected --output-root PATH, got: #{inspect(other)}"
  end

unless plan.optimizer.use_merge == false and
         plan.status == :readiness_only and
         plan.data_readiness.data_ready == false and
         plan.optimizer.execution_profile == :gepa_v0_1_4 and
         plan.transports.nominal_total == 115_248 and
         plan.transports.legal_total == 122_520 do
  raise "HoVer no-merge plan does not match the frozen opportunity"
end

results =
  Enum.map(plan.seeds, fn seed ->
    seed_root = Path.join(output_root, Integer.to_string(seed))
    HoverGepaNoMergePlan.provider_disabled_lifecycle!(seed_root, seed)
  end)

IO.puts(Jason.encode!(%{plan: plan, provider_disabled_results: results}))
