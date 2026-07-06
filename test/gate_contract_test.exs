defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production gate aliases stay wired to the documented release commands" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test --exclude live --exclude integration --exclude protocol_training --exclude protocol_retriever --exclude protocol_mcp",
             "benchmark.truth.check",
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
             "test test/benchmark_truth_test.exs"
           ]

    assert Keyword.fetch!(aliases, :"benchmark.live.check") == [
             "dsex.benchmark.fetch --tasks gsm8k,hotpotqa --length 2 --out benchmarks/data",
             "dsex.benchmark.run --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2 --live"
           ]

    assert Keyword.fetch!(aliases, :"live.check") == [
             "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
           ]

    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".training.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".retriever.check"))
    refute Keyword.has_key?(aliases, String.to_atom("live" <> ".mcp.check"))
  end
end
