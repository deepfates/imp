defmodule LiveRetrieverGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_retriever

  test "live retriever gate is explicit because it depends on external services" do
    assert System.get_env("LIVE_RETRIEVER") in [nil, "0", "1"]
  end
end
