defmodule BenchmarkCatalogTest do
  use ExUnit.Case, async: true

  test "catalog names implemented and missing DSPy-derived benchmark families" do
    catalog = Imp.BenchmarkCatalog.catalog()
    families = catalog.families
    by_id = Map.new(families, &{&1.id, &1})

    assert catalog.schema_version == 1
    assert catalog.sources.dspy_docs == "https://dspy.ai/"
    assert catalog.sources.dspy_paper == "https://arxiv.org/abs/2310.03714"

    assert by_id["math_gsm8k"].status == "implemented"
    assert by_id["qa_hotpotqa"].status == "provider_free_implemented"
    assert by_id["classification_colors"].status == "provider_free_implemented"
    assert by_id["rag_retrieval"].status == "provider_free_implemented"
    assert by_id["tools_react"].status == "provider_free_implemented"
    assert by_id["rlm_recursive_control"].status == "deterministic_implemented"
    assert by_id["program_composition_orchestration"].status == "provider_free_implemented"
    assert by_id["adapter_streaming_structured_io"].status == "provider_free_and_live_implemented"

    assert by_id["operations_persistence_observability"].status ==
             "test_coverage_plus_source_bound_recovery_evidence"

    assert by_id["multimodal_primitives"].status == "deterministic_implemented"
    assert by_id["optimizer_lift"].status == "provider_free_implemented"
    assert by_id["gepa_paper_replication"].status == "artifact_contract_implemented"
    assert by_id["factuality_classification"].status == "missing"
    assert by_id["mipro_tabular"].status == "samplers_implemented_optimizer_scale_missing"
    assert by_id["mipro_scone"].status == "missing"

    assert by_id["hover_verification"].status ==
             "source_exact_capped_live_present_full_scale_pending"

    assert by_id["ifbench_instruction_following"].status == "provider_free_implemented"
    assert by_id["hard_math"].status == "provider_free_implemented"
    assert by_id["finetuning_training"].status == "protocol_plus_local_effectiveness"
    assert by_id["privacy_delegation"].status == "missing"
    assert by_id["livebench_math"].status == "deferred"

    assert "mix benchmark.parity.full" in by_id["math_gsm8k"].commands
    assert "mix benchmark.truth.check" in by_id["classification_colors"].commands
    assert "mix benchmark.gepa_replication.check" in by_id["gepa_paper_replication"].commands
    assert by_id["factuality_classification"].next_step =~ "generic classification/QA sampler"
    assert by_id["rag_retrieval"].next_step =~ "larger retrieval corpora"
    assert by_id["rlm_recursive_control"].metric =~ "budget"
    assert by_id["program_composition_orchestration"].next_step =~ "matched Imp/DSPy"

    assert "mix test test/operations_stress_test.exs test/stream_listener_incremental_test.exs" in by_id[
             "adapter_streaming_structured_io"
           ].commands

    assert "mix test test/operations_stress_test.exs test/adversarial_security_stress_test.exs" in by_id[
             "operations_persistence_observability"
           ].commands

    assert "mix benchmark.failure_campaign.check" in by_id[
             "operations_persistence_observability"
           ].commands

    assert by_id["adapter_streaming_structured_io"].metric =~ "incremental field"
    assert by_id["operations_persistence_observability"].metric =~ "secret absence"
    refute "mix benchmark.operations_stress.check" in by_id["multimodal_primitives"].commands
    assert by_id["multimodal_primitives"].task_shape =~ "content parts"

    assert "mix benchmark.instruction_optimizer.contract.check" in by_id["optimizer_lift"].commands

    assert by_id["optimizer_lift"].next_step =~ "multi-seed"
    assert by_id["mipro_tabular"].next_step =~ "Iris"
    assert "mix imp.benchmark.gepa_campaign" in by_id["hover_verification"].commands
    assert by_id["hover_verification"].next_step =~ "uncapped"
    assert "mix benchmark.truth.check" in by_id["ifbench_instruction_following"].commands
    assert "mix benchmark.truth.check" in by_id["hard_math"].commands
    assert "mix imp.benchmark.local_mlx" in by_id["finetuning_training"].commands
    assert by_id["ifbench_instruction_following"].metric =~ "constraint"
  end

  test "catalog task writes JSON artifact" do
    out_dir = Path.join(System.tmp_dir!(), "imp-catalog-#{System.unique_integer([:positive])}")
    out_path = Path.join(out_dir, "catalog.json")

    Mix.Tasks.Imp.Benchmark.Catalog.run(["--format", "json", "--out", out_path])

    assert File.exists?(out_path)
    artifact = out_path |> File.read!() |> Jason.decode!(keys: :atoms)
    assert artifact.schema_version == 1
    assert Enum.any?(artifact.families, &(&1.id == "optimizer_lift"))
    assert Enum.any?(artifact.families, &(&1.status == "missing"))
  end
end
