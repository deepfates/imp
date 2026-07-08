defmodule BenchmarkCatalogTest do
  use ExUnit.Case, async: true

  test "catalog names implemented and missing DSPy-derived benchmark families" do
    catalog = DSEx.BenchmarkCatalog.catalog()
    families = catalog.families
    by_id = Map.new(families, &{&1.id, &1})

    assert catalog.schema_version == 1
    assert catalog.sources.dspy_docs == "https://dspy.ai/"
    assert catalog.sources.dspy_paper == "https://arxiv.org/abs/2310.03714"

    assert by_id["math_gsm8k"].status == "implemented"
    assert by_id["qa_hotpotqa"].status == "partially_implemented"
    assert by_id["classification_colors"].status == "loader_only"
    assert by_id["rag_retrieval"].status == "provider_free_implemented"
    assert by_id["tools_react"].status == "provider_free_implemented"
    assert by_id["rlm_recursive_control"].status == "deterministic_implemented"
    assert by_id["program_composition_orchestration"].status == "deterministic_implemented"
    assert by_id["adapter_streaming_structured_io"].status == "deterministic_and_live_implemented"
    assert by_id["operations_persistence_observability"].status == "deterministic_implemented"
    assert by_id["multimodal_primitives"].status == "deterministic_implemented"
    assert by_id["optimizer_lift"].status == "provider_free_implemented"
    assert by_id["factuality_classification"].status == "missing"
    assert by_id["mipro_tabular"].status == "missing"
    assert by_id["mipro_scone"].status == "missing"
    assert by_id["hover_verification"].status == "missing"
    assert by_id["ifbench_instruction_following"].status == "missing"
    assert by_id["hard_math"].status == "loader_only"
    assert by_id["privacy_delegation"].status == "missing"
    assert by_id["livebench_math"].status == "deferred"

    assert "mix benchmark.parity.full" in by_id["math_gsm8k"].commands
    assert by_id["factuality_classification"].next_step =~ "generic classification/QA sampler"
    assert by_id["rag_retrieval"].next_step =~ "real small corpus retrieval benchmark"
    assert by_id["rlm_recursive_control"].metric =~ "budget"
    assert by_id["program_composition_orchestration"].next_step =~ "BestOfN"
    assert by_id["adapter_streaming_structured_io"].metric =~ "incremental field"
    assert by_id["operations_persistence_observability"].metric =~ "secret absence"
    assert by_id["multimodal_primitives"].task_shape =~ "content parts"
    assert by_id["mipro_tabular"].next_step =~ "Iris"
    assert by_id["ifbench_instruction_following"].metric =~ "constraint"
  end

  test "catalog task writes JSON artifact" do
    out_dir = Path.join(System.tmp_dir!(), "dsex-catalog-#{System.unique_integer([:positive])}")
    out_path = Path.join(out_dir, "catalog.json")

    Mix.Tasks.Dsex.Benchmark.Catalog.run(["--format", "json", "--out", out_path])

    assert File.exists?(out_path)
    artifact = out_path |> File.read!() |> Jason.decode!(keys: :atoms)
    assert artifact.schema_version == 1
    assert Enum.any?(artifact.families, &(&1.id == "optimizer_lift"))
    assert Enum.any?(artifact.families, &(&1.status == "missing"))
  end
end
