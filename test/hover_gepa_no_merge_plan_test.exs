defmodule Imp.BenchmarkTruth.HoverGepaNoMergePlanTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.HoverGepaNoMergePlan

  @tag :evidence_infrastructure
  test "authenticates the no-merge authorities and derives nominal and legal opportunity" do
    assert :ok = HoverGepaNoMergePlan.verify_authorities!()
    plan = HoverGepaNoMergePlan.design()

    assert plan.status == :readiness_only
    assert plan.data_readiness.data_ready == false
    assert plan.data_readiness.reason =~ "build-receipt"
    assert plan.retrieval.authority_scope == :condition_build_instance_receipt
    assert plan.retrieval.planned_runtime_entries == [:imp, :dspy]

    assert plan.retrieval.index_build_instance_tree_sha256 ==
             "d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548"

    assert plan.retrieval.frozen_claim_retrieval_fingerprint_sha256 ==
             "2662ef6b6a4f8f80b9d348992f14ca04d3007c84b13252825dc38a55ace22099"

    assert plan.rows == %{train: 150, selection: 300, test: 300}
    assert plan.split_policy.output_blind

    assert plan.split_policy.kind ==
             :released_split_with_content_identity_overlap_removed

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

  @tag :evidence_infrastructure
  test "condition receipt requires both runtimes, exact receipt, and exact fingerprint" do
    root = Path.expand("tmp/hover-materialization-v1")
    data_root = Path.join(root, "export-disjoint-v1/hoverBench")
    receipt_path = Path.join(root, "materialization.json")
    split_receipt_path = Path.join(root, "export-disjoint-v1/families.json")
    lock_path = Path.join(root, "dependency-lock.txt")

    fingerprint_path =
      Path.join(root, "retrieval/frozen-disjoint-claim-retrieval-fingerprint.jsonl")

    corpus_path = Path.join(root, "retrieval/extracted/wiki.abstracts.2017.jsonl")
    index_path = Path.join(root, "retrieval/index/bm25s_retriever")

    retrieval = %{
      "kind" => "bm25s_wiki_abstracts_2017",
      "corpus_path" => corpus_path,
      "index_path" => index_path,
      "corpus_checksum" =>
        "sha256:c006527c7c600f85ed594afa36d2a34d0598996405f560474227738342463724",
      "index_checksum" =>
        "sha256:d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548"
    }

    common = [
      data_root: data_root,
      receipt_path: receipt_path,
      split_receipt_path: split_receipt_path,
      dependency_lock_path: lock_path,
      fingerprint_path: fingerprint_path
    ]

    assert_raise ArgumentError, ~r/Imp and DSPy/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        Keyword.put(common, :runtime_retrievals, %{imp: retrieval})
      )
    end

    altered_receipt = temporary_path("altered-receipt")

    File.write!(
      altered_receipt,
      File.read!(receipt_path)
      |> String.replace(
        "d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548",
        String.duplicate("0", 64),
        global: false
      )
    )

    on_exit(fn -> File.rm_rf!(altered_receipt) end)

    assert_raise ArgumentError, ~r/build receipt/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        common
        |> Keyword.put(:receipt_path, altered_receipt)
        |> Keyword.put(:runtime_retrievals, %{imp: retrieval, dspy: retrieval})
      )
    end

    altered_fingerprint = temporary_path("altered-fingerprint")
    File.write!(altered_fingerprint, File.read!(fingerprint_path) <> "{}\n")
    on_exit(fn -> File.rm_rf!(altered_fingerprint) end)

    assert_raise ArgumentError, ~r/fingerprint/, fn ->
      HoverGepaNoMergePlan.data_readiness(
        common
        |> Keyword.put(:fingerprint_path, altered_fingerprint)
        |> Keyword.put(:runtime_retrievals, %{imp: retrieval, dspy: retrieval})
      )
    end

    assert %{data_ready: true, runtime_entries: [:imp, :dspy]} =
             HoverGepaNoMergePlan.data_readiness(
               Keyword.put(common, :runtime_retrievals, %{imp: retrieval, dspy: retrieval})
             )
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
  test "loads the exact source splits and keeps one resident source-exact retriever" do
    root = Path.expand("tmp/hover-materialization-v1")
    data = HoverGepaNoMergePlan.data!(root)

    assert length(data.train) == 150
    assert length(data.selection) == 300
    assert length(data.test) == 300

    assert HoverGepaNoMergePlan.source_exact_retrieval_probe!(root) == %{
             queries: 2,
             top_k: 24,
             repeat_exact: true,
             fingerprint_exact: true,
             implementation: "resident_upstream_python_bm25s"
           }
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
        [
          "run",
          "scripts/hover_gepa_no_merge_current.exs",
          "--output-root",
          root,
          "--material-root",
          Path.expand("tmp/hover-materialization-v1")
        ],
        env: [{"OPENAI_API_KEY", ""}, {"ANTHROPIC_API_KEY", ""}],
        stderr_to_stdout: true
      )

    payload = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert get_in(payload, ["plan", "condition"]) ==
             "imp-88sn-hover-gepa-no-merge-identity-disjoint-v1"

    assert get_in(payload, ["plan", "data_readiness", "data_ready"]) == true

    assert payload["source_exact_retrieval_probe"] == %{
             "queries" => 2,
             "top_k" => 24,
             "repeat_exact" => true,
             "fingerprint_exact" => true,
             "implementation" => "resident_upstream_python_bm25s"
           }

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
