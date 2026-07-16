defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production gate aliases stay wired to the documented release commands" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "clean",
             "compile --warnings-as-errors",
             "legacy_identity.check",
             "test --raise --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp --exclude package",
             "benchmark.failure_campaign.check",
             "package.check",
             "livebook.check",
             "docs.clean",
             "docs"
           ]

    assert [docs_clean] = Keyword.fetch!(aliases, :"docs.clean")
    assert is_function(docs_clean, 1)

    assert Keyword.fetch!(aliases, :"evidence.check") == [
             "reproduction.check",
             "research.portfolio.check",
             "benchmark.truth.check",
             "benchmark.trace.check",
             "benchmark.failure_campaign.check",
             "benchmark.search.check",
             "benchmark.optimizer_lift.check",
             "benchmark.instruction_optimizer.contract.check",
             "benchmark.gepa_replication.check",
             "benchmark.fast_slow.check",
             "benchmark.optimize_anything.check",
             "benchmark.rag_tool_agent.check",
             "benchmark.bfcl_scorer.check",
             "benchmark.copro_isolation.check",
             "benchmark.rag_tool_failure.check",
             "benchmark.rlm.check",
             "benchmark.rlm.contract.check",
             "upstream_fidelity.check"
           ]

    assert Keyword.fetch!(aliases, :"upstream_fidelity.check") == [
             "imp.upstream_fidelity --out tmp/upstream-fidelity/upstream-fidelity.json --require-conformant"
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
             "imp.benchmark.fetch --tasks colors,iris,iris_typo,heart_disease,ifbench_instruction_following,hard_math --full --out tmp/benchmark-truth-local",
             "imp.benchmark.run --colors tmp/benchmark-truth-local/colors-test-0-6.jsonl --iris tmp/benchmark-truth-local/iris-test-0-6.jsonl --iris-typo tmp/benchmark-truth-local/iris_typo-test-0-3.jsonl --heart-disease tmp/benchmark-truth-local/heart_disease-test-0-4.jsonl --ifbench-instruction-following tmp/benchmark-truth-local/ifbench_instruction_following-test-0-3.jsonl --hard-math tmp/benchmark-truth-local/hard_math-test-0-3.jsonl --max-examples 6 --out tmp/benchmark-truth-local-results",
             "imp.benchmark.integrity --gsm8k test/fixtures/benchmarks/gsm8k-small.jsonl --hotpotqa test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/benchmark-integrity --require-clean"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.catalog") == [
             "imp.benchmark.catalog --format json --out tmp/benchmark-catalog.json"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.trace.check") == [
             "imp.benchmark.trace --out tmp/golden-trace"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.operations_stress.check") == [
             "imp.benchmark.operations_stress --out tmp/operations-stress"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.failure_campaign.check") == [
             "imp.benchmark.failure_campaign --iterations 10 --require-clean --out tmp/failure-campaign"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.overhead.check") == [
             "imp.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --require-clean --out tmp/overhead"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.search.check") == [
             "imp.benchmark.search --iterations 10 --max-concurrency 2 --work-ms 10 --out tmp/search-benchmark"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.optimizer_lift.check") == [
             "imp.benchmark.optimizer_lift --out tmp/optimizer-lift"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.instruction_optimizer.contract.check") == [
             "imp.benchmark.instruction_optimizer_contract --out tmp/instruction-optimizer-contract"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.gepa_replication.check") == [
             "imp.benchmark.gepa_replication --smoke --out tmp/gepa-replication"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.fast_slow.check") == [
             "imp.benchmark.fast_slow --out tmp/fast-slow-protocol.json"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rag_tool_agent.check") == [
             "imp.benchmark.rag_tool_agent --out tmp/rag-tool-agent"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.bfcl_scorer.check") == [
             "imp.benchmark.bfcl_adapted --no-require-clean --out tmp/bfcl-shaped-scorer"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rag_tool_failure.check") == [
             "imp.benchmark.rag_tool_failure_differential --no-require-clean --out tmp/rag-tool-failure-differential"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rlm.check") == [
             "imp.benchmark.rlm --data test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/rlm-benchmark"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rlm.contract.check") == [
             "cmd tmp/dspy-current-venv/bin/python test/python_verify_dspy_current_target_test.py",
             "cmd tmp/dspy-current-venv/bin/python test/python_dspy_rlm_campaign_test.py",
             "cmd tmp/dspy-current-venv/bin/python test/python_dspy_rlm_wrapper_integration_test.py",
             "imp.benchmark.rlm_contract --cases test/fixtures/rlm_contract_cases.json --out tmp/rlm-contract-current"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live_matrix") == [
             "imp.benchmark.live_matrix --in benchmarks/runs/parity/imp-dspy-parity-campaign-*.json --out tmp/live-matrix"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.optimize_anything.check") == [
             "imp.benchmark.optimize_anything --smoke --out tmp/optimize-anything"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard") == [
             "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard.ready") == [
             "imp.benchmark.dashboard --profile v0.1 --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard --require-ready"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard.telos") == [
             "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard.telos.ready") == [
             "imp.benchmark.dashboard --profile telos --trace-dir tmp/golden-trace --failure-campaign-dir tmp/failure-campaign --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --instruction-optimizer-dir tmp/instruction-optimizer-contract --gepa-dir tmp/gepa-replication --optimize-anything-dir benchmarks/evidence/admitted/optimize_anything --rlm-dir tmp/rlm-benchmark --live-matrix-dir tmp/live-matrix --results-dir benchmarks/runs --gate-dir tmp/gate-evidence --out tmp/dashboard --require-ready"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live.check") == [
             "imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
             "imp.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2 --live"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.parity.check") == [
             "imp.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
             "imp.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.parity.full") == [
             "imp.benchmark.fetch --tasks gsm8k,hotpotqa --full --out benchmarks/data",
             "imp.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-1319.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-7405.jsonl --max-examples 7405"
           ]

    assert Keyword.fetch!(aliases, :"live.check") == [
             "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
           ]

    assert Keyword.fetch!(aliases, :"package.check") == [
             "package.clean",
             "test test/package_contract_test.exs",
             "cmd mix hex.build --unpack --output tmp/package-check",
             "imp.package.clean_room --package tmp/package-check"
           ]

    assert Keyword.fetch!(aliases, :"livebook.check") == [
             "test.livebooks --path livebooks"
           ]

    assert Keyword.fetch!(aliases, :"livebook.execute.check") == [
             "test.livebooks --path livebooks --execute"
           ]

    assert Keyword.fetch!(aliases, :"legacy_identity.check") == [
             "run scripts/legacy_identity_audit.exs"
           ]

    assert Keyword.fetch!(aliases, :"quality.check") == [
             "legacy_identity.check",
             "credo --only warning",
             "cmd mix hex.audit"
           ]

    assert Keyword.fetch!(aliases, :"gate.package.evidence") == [
             "imp.gate_evidence --gate product_package --mix-task package.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.livebook.evidence") == [
             "imp.gate_evidence --gate livebook_execute --mix-task livebook.execute.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.protocol.evidence") == [
             "imp.gate_evidence --gate protocol_gates --mix-task protocol.check --out tmp/gate-evidence"
           ]

    assert Keyword.fetch!(aliases, :"gate.live_provider.evidence") == [
             "imp.gate_evidence --gate live_provider_smoke --mix-task live.check --env-file .env --env LIVE_PROVIDER=1 --out tmp/gate-evidence"
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

    assert filter_modules.(Imp, %{})
    assert filter_modules.(Imp.Predict.ChainOfThought, %{})

    refute filter_modules.(Imp.Benchmarks, %{})
    refute filter_modules.(Imp.BenchmarkTruth, %{})
    refute filter_modules.(Mix.Tasks.Imp.Benchmark.Parity, %{})
  end
end
