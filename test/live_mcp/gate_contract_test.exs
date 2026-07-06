defmodule LiveMCPGateContractTest do
  use ExUnit.Case, async: true

  @moduletag :live_mcp

  test "live MCP gate is explicit because it depends on external MCP servers" do
    assert System.get_env("LIVE_MCP") in [nil, "0", "1"]
  end
end
