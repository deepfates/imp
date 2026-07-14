defmodule IntegrationGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  test "integration gate is reserved for local service end-to-end tests" do
    aliases = Imp.MixProject.project() |> Keyword.fetch!(:aliases)

    assert Keyword.fetch!(aliases, :"integration.check") == [
             "test --only integration test/integration"
           ]
  end
end
