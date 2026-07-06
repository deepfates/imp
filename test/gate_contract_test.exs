defmodule GateContractTest do
  use ExUnit.Case, async: true

  test "production and v2 gates encode the release contract" do
    aliases = Mix.Project.config() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"production.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test",
             "docs"
           ]

    assert Keyword.fetch!(aliases, :"v2.check") == [
             "format --check-formatted",
             "compile --warnings-as-errors",
             "test --include v2"
           ]

    assert Keyword.fetch!(aliases, :"live.check") == [
             "test --include live test/live_provider_test.exs test/live_provider_e2e_test.exs"
           ]
  end
end
