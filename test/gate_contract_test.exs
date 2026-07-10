defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production gate aliases stay wired to the documented release commands" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package",
             "package.check",
             "livebook.check",
             "docs.clean",
             "docs"
           ]

    assert [docs_clean] = Keyword.fetch!(aliases, :"docs.clean")
    assert is_function(docs_clean, 1)

    assert Keyword.fetch!(aliases, :"evidence.check") == [
             "benchmark.truth.check",
             "benchmark.trace.check",
             "benchmark.operations_stress.check",
             "benchmark.overhead.check",
             "benchmark.optimizer_lift.check",
             "benchmark.gepa_replication.check",
             "benchmark.rag_tool_agent.check",
             "benchmark.rlm.check",
             "upstream_fidelity.check"
           ]

    assert Keyword.fetch!(aliases, :"upstream_fidelity.check") == [
             "dsex.upstream_fidelity --out tmp/upstream-fidelity/upstream-fidelity.json --require-conformant"
           ]

    retired_gate = String.to_atom("v2" <> ".check")
    refute Keyword.has_key?(aliases, retired_gate)

    assert Keyword.fetch!(aliases, :"integration.check") == [
             "test --only integration test/integration"
           ]

    assert Keyword.fetch!(aliases, :"protocol.check") == [
             "test --include protocol_training --include protocol_retriever --include protocol_mcp test/protocol_training test/protocol_retriever test/protocol_mcp"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.truth.check") == [
             "test test/benchmark_truth_test.exs",
             "dsex.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease,ifbench_instruction_following,hard_math --full --out tmp/benchmark-truth-local",
             "dsex.benchmark.run --colors tmp/benchmark-truth-local/colors-test-0-6.jsonl --iris tmp/benchmark-truth-local/iris-test-0-6.jsonl --iris-typo tmp/benchmark-truth-local/iris_typo-test-0-3.jsonl --heart-disease tmp/benchmark-truth-local/heart_disease-test-0-4.jsonl --ifbench-instruction-following tmp/benchmark-truth-local/ifbench_instruction_following-test-0-3.jsonl --hard-math tmp/benchmark-truth-local/hard_math-test-0-3.jsonl --max-examples 6 --out tmp/benchmark-truth-local-results",
             "dsex.benchmark.integrity --gsm8k test/fixtures/benchmarks/gsm8k-small.jsonl --hotpotqa test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/benchmark-integrity --require-clean"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.catalog") == [
             "dsex.benchmark.catalog --format json --out tmp/benchmark-catalog.json"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.trace.check") == [
             "dsex.benchmark.trace --out tmp/golden-trace"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.operations_stress.check") == [
             "dsex.benchmark.operations_stress --out tmp/operations-stress"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.overhead.check") == [
             "dsex.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --out tmp/overhead --max-ratio 50.0"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.optimizer_lift.check") == [
             "dsex.benchmark.optimizer_lift --out tmp/optimizer-lift"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.gepa_replication.check") == [
             "dsex.benchmark.gepa_replication --smoke --out tmp/gepa-replication"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rag_tool_agent.check") == [
             "dsex.benchmark.rag_tool_agent --out tmp/rag-tool-agent"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rlm.check") == [
             "dsex.benchmark.rlm --data test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/rlm-benchmark"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live_matrix") == [
             "dsex.benchmark.live_matrix --in benchmarks/results/dsex-dspy-parity-campaign-*.json --out tmp/live-matrix"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard") == [
             "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --gepa-dir tmp/gepa-replication --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard.full") == [
             "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --gepa-dir tmp/gepa-replication --rag-tool-agent-dir tmp/rag-tool-agent --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --gate-dir tmp/gate-evidence --out tmp/dashboard --require-full"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live.check") == [
             "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
             "dsex.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2 --live"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.parity.check") == [
             "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
             "dsex.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.parity.full") == [
             "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data",
             "dsex.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl --max-examples 7405"
           ]

    assert Keyword.fetch!(aliases, :"live.check") == [
             "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
           ]

    assert Keyword.fetch!(aliases, :"package.check") == [
             "test test/package_contract_test.exs",
             "cmd mix hex.build --unpack --output tmp/package-check"
           ]

    assert Keyword.fetch!(aliases, :"livebook.check") == [
             "test.livebooks --path livebooks"
           ]

    assert Keyword.fetch!(aliases, :"livebook.execute.check") == [
             "test.livebooks --path livebooks --execute"
           ]

    assert Keyword.fetch!(aliases, :"quality.check") == [
             "credo --only warning",
             "cmd mix hex.audit"
           ]

    assert Keyword.fetch!(aliases, :"gate.package.evidence") == [
             "dsex.gate_evidence --gate product_package --mix-task package.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.livebook.evidence") == [
             "dsex.gate_evidence --gate livebook_execute --mix-task livebook.execute.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.protocol.evidence") == [
             "dsex.gate_evidence --gate protocol_gates --mix-task protocol.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.live_provider.evidence") == [
             "dsex.gate_evidence --gate live_provider_smoke --mix-task live.check --env-file .env --env LIVE_PROVIDER=1 --out tmp/gate-evidence"
           ]

    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".training.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".retriever.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".mcp.check"))
  end

  test "generated docs expose the product API, not local validation machinery" do
    filter_modules =
      Mix.Project.config()
      |> Keyword.fetch!(:docs)
      |> Keyword.fetch!(:filter_modules)

    assert filter_modules.(DSEx, %{})
    assert filter_modules.(DSEx.Predict.ChainOfThought, %{})

    refute filter_modules.(DSEx.Benchmarks, %{})
    refute filter_modules.(DSEx.BenchmarkTruth, %{})
    refute filter_modules.(Mix.Tasks.Dsex.Benchmark.Parity, %{})
  end
end
