defmodule Imp.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.ToolPolicy

  test "a policy function answers :allow or {:deny, reason}, and the reason is kept" do
    policy = fn name, _args -> if name == :read, do: :allow, else: {:deny, :read_only} end

    assert :ok = ToolPolicy.authorize(policy, :read, %{})

    assert {:error, {:tool_denied, :write, :read_only}} =
             ToolPolicy.authorize(policy, :write, %{})
  end

  test "anything else from a policy function refuses the call" do
    for answer <- [true, :ok, false, {:error, :nope}] do
      assert {:error, {:tool_denied, :write, {:invalid_decision, ^answer}}} =
               ToolPolicy.authorize(fn _name, _args -> answer end, :write, %{})
    end
  end

  test "a name or list policy refuses what it does not name" do
    assert :ok = ToolPolicy.authorize([:read, "search"], "read", %{})

    assert {:error, {:tool_denied, :write, :tool_policy}} =
             ToolPolicy.authorize(:read, :write, %{})
  end
end
