defmodule V2GatePlaceholderTest do
  use ExUnit.Case, async: true

  @tag :v2
  test "V2 roadmap exists and is intentionally enforced by mix v2.check" do
    assert File.exists?("V2_ROADMAP.md")
  end
end
