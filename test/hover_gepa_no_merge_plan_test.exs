defmodule Imp.BenchmarkTruth.HoverGepaNoMergePlanTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.HoverGepaNoMergePlan

  @tag :evidence_infrastructure
  test "authenticates the no-merge authorities and derives nominal and legal opportunity" do
    assert :ok = HoverGepaNoMergePlan.verify_authorities!()
    plan = HoverGepaNoMergePlan.design()

    assert plan.status == :readiness_only
    assert plan.data_readiness.data_ready == false
    assert plan.data_readiness.reason =~ "not materialized"
    assert plan.rows == %{train: 150, selection: 300, test: 300}
    assert plan.optimizer.execution_profile == :gepa_v0_1_4
    refute plan.optimizer.use_merge
    assert plan.optimizer.semantic_max_metric_calls == 1_200
    assert plan.optimizer.operational_metric_calls == 1_503
    assert plan.optimizer.generations == 300
    assert plan.optimizer.logical_reflections == 300
    assert plan.optimizer.legal_reflection_transports == 600
    assert plan.transports.nominal_task_per_runtime_seed == 19_200
    assert plan.transports.legal_task_per_runtime_seed == 20_412
    assert plan.transports.nominal_total == 115_248
    assert plan.transports.legal_total == 122_520
    assert plan.transports.logical_reflections_all_runtimes_seeds == 1_800
    assert plan.transports.legal_reflection_transports_all_runtimes_seeds == 3_600
  end

  test "constructs only the frozen public pinned profile" do
    metric = fn _example, _prediction -> 1.0 end
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "unused" end)

    optimizer = HoverGepaNoMergePlan.optimizer(metric, lm, 2_026_080_201)

    assert optimizer.execution_profile == :gepa_v0_1_4
    assert optimizer.reflection_record_mode == :gepa_v0_1_4
    assert optimizer.module_selector == :round_robin
    refute optimizer.use_merge
    assert optimizer.minibatch_size == 3
    assert optimizer.generations == 300
    assert optimizer.max_metric_calls == 1_200
    assert optimizer.max_reflection_calls == 600

    assert Enum.sort(Map.keys(optimizer.component_feedback)) ==
             [:create_query_hop2, :create_query_hop3, :summarize1, :summarize2]

    assert_raise ArgumentError, ~r/unfrozen HoVer seed/, fn ->
      HoverGepaNoMergePlan.optimizer(metric, lm, 17)
    end
  end

  @tag :evidence_infrastructure
  test "compact provider-disabled lifecycle exercises four mutations, rejection, selection, and fresh service" do
    root = temporary_path("lifecycle")
    on_exit(fn -> File.rm_rf!(root) end)

    result = HoverGepaNoMergePlan.provider_disabled_lifecycle!(root, 2_026_080_201)

    assert result.proposal_components == [
             "summarize1",
             "create_query_hop2",
             "summarize2",
             "create_query_hop3",
             "summarize1"
           ]

    assert result.changed_predictors ==
             ~w(create_query_hop2 create_query_hop3 summarize1 summarize2)

    assert result.rejected_candidates == 1
    assert result.optimizer_metric_calls == 30
    assert result.optimizer_reflection_calls == 5
    assert result.baseline_selection == 0.0
    assert_in_delta result.optimized_selection, 0.8, 1.0e-12
    assert result.selected == :optimized
    assert result.baseline_test == 0.0
    assert_in_delta result.selected_test, 0.8, 1.0e-12
    assert result.fresh_service == %{"all_ok" => true, "calls" => 4}
    assert File.exists?(Path.join(root, "artifact-2026080201.json"))
    assert File.exists?(Path.join(root, "result-2026080201.json"))
  end

  @tag :evidence_infrastructure
  test "provider-disabled invocation authenticates the plan and runs all three compact seeds" do
    root = temporary_path("entry")
    on_exit(fn -> File.rm_rf!(root) end)

    {output, 0} =
      System.cmd(
        "mix",
        ["run", "scripts/hover_gepa_no_merge_current.exs", "--output-root", root],
        env: [{"OPENAI_API_KEY", ""}, {"ANTHROPIC_API_KEY", ""}],
        stderr_to_stdout: true
      )

    payload = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert get_in(payload, ["plan", "condition"]) == "imp-88sn-hover-gepa-no-merge-current-v1"

    assert Enum.map(payload["provider_disabled_results"], & &1["seed"]) ==
             [2_026_080_201, 2_026_080_202, 2_026_080_203]

    assert Enum.all?(payload["provider_disabled_results"], fn result ->
             result["fresh_service"] == %{"all_ok" => true, "calls" => 4} and
               result["proposal_components"] ==
                 ~w(summarize1 create_query_hop2 summarize2 create_query_hop3 summarize1)
           end)
  end

  defp temporary_path(name) do
    Path.join(System.tmp_dir!(), "imp-hover-plan-#{System.unique_integer([:positive])}-#{name}")
  end
end
