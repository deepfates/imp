alias Imp.BenchmarkTruth.HoverGepaNoMergePlan

if System.get_env("LIVE_PROVIDER") == "1" do
  raise "HoVer planner checkpoint is provider-disabled; live execution is not authorized"
end

:ok = HoverGepaNoMergePlan.verify_authorities!()

{output_root, material_root} =
  case System.argv() do
    ["--output-root", output_root, "--material-root", material_root] ->
      {Path.expand(output_root), Path.expand(material_root)}

    other ->
      raise "expected --output-root PATH --material-root PATH, got: #{inspect(other)}"
  end

materialization = HoverGepaNoMergePlan.materialization_options(material_root)
plan = HoverGepaNoMergePlan.design(materialization)

unless plan.optimizer.use_merge == false and
         plan.status == :readiness_only and
         plan.data_readiness.data_ready == true and
         plan.optimizer.execution_profile == :gepa_v0_1_4 and
         plan.transports.nominal_total == 115_248 and
         plan.transports.legal_total == 122_520 do
  raise "HoVer no-merge plan does not match the frozen opportunity"
end

retrieval_probe =
  HoverGepaNoMergePlan.source_exact_retrieval_probe!(material_root,
    gepa_root: "tmp/gepa-artifact"
  )

results =
  Enum.map(plan.seeds, fn seed ->
    seed_root = Path.join(output_root, Integer.to_string(seed))
    HoverGepaNoMergePlan.provider_disabled_lifecycle!(seed_root, seed)
  end)

IO.puts(
  Jason.encode!(%{
    plan: plan,
    source_exact_retrieval_probe: retrieval_probe,
    provider_disabled_results: results
  })
)
