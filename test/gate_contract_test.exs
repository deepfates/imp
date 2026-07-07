defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production gate aliases stay wired to the documented release commands" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp",
             "benchmark.truth.check",
             "benchmark.trace.check",
             "benchmark.overhead.check",
             "benchmark.optimizer_lift.check",
             "benchmark.rag_tool_agent.check",
             "docs"
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
             "dsex.benchmark.integrity --gsm8k test/fixtures/benchmarks/gsm8k-small.jsonl --hotpotqa test/fixtures/benchmarks/hotpotqa-small.jsonl --out tmp/benchmark-integrity --require-clean"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.trace.check") == [
             "dsex.benchmark.trace --out tmp/golden-trace"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.overhead.check") == [
             "dsex.benchmark.overhead --iterations 30 --warmup 5 --batch-size 10 --out tmp/overhead --max-ratio 50.0"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.optimizer_lift.check") == [
             "dsex.benchmark.optimizer_lift --out tmp/optimizer-lift"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.rag_tool_agent.check") == [
             "dsex.benchmark.rag_tool_agent --out tmp/rag-tool-agent"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live_matrix") == [
             "dsex.benchmark.live_matrix --in benchmarks/results/dsex-dspy-parity-campaign-*.json --out tmp/live-matrix"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard") == [
             "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --rag-tool-agent-dir tmp/rag-tool-agent --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --out tmp/dashboard"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.dashboard.full") == [
             "dsex.benchmark.dashboard --trace-dir tmp/golden-trace --overhead-dir tmp/overhead --optimizer-dir tmp/optimizer-lift --rag-tool-agent-dir tmp/rag-tool-agent --live-matrix-dir tmp/live-matrix --results-dir benchmarks/results --out tmp/dashboard --require-full"
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

    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".training.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".retriever.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".mcp.check"))
  end
end
