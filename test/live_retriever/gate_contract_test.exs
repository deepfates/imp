defmodule LiveRetrieverGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_retriever

  test "live retriever alias is reserved until real external-service tests are configured" do
    assert System.get_env("LIVE_RETRIEVER") in [nil, "0", "1"]
  end
end
