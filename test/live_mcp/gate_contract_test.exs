defmodule LiveMCPGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_mcp

  test "live MCP alias is reserved until real external-server tests are configured" do
    assert System.get_env("LIVE_MCP") in [nil, "0", "1"]
  end
end
