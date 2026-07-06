defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production gates encode the release contract" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test --exclude live --exclude integration --exclude live_training --exclude live_retriever --exclude live_mcp",
             "docs"
           ]

    retired_gate = String.to_atom("v2" <> ".check")
    refute Keyword.has_key?(aliases, retired_gate)

    assert Keyword.fetch!(aliases, :"integration.check") == [
             "test --only integration test/integration"
           ]

    assert Keyword.fetch!(aliases, :"live.check") == [
             "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
           ]

    assert Keyword.fetch!(aliases, :"live.training.check") == [
             "test --only live_training test/live_training"
           ]

    assert Keyword.fetch!(aliases, :"live.retriever.check") == [
             "test --only live_retriever test/live_retriever"
           ]

    assert Keyword.fetch!(aliases, :"live.mcp.check") == [
             "test --only live_mcp test/live_mcp"
           ]
  end
end
