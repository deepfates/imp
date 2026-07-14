defmodule RLMBudgetTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.RLM.Budget

  test "atomically reserves calls and shares recursion depth" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 3, max_recursion_depth: 2)

    assert {:ok, 2} = Budget.reserve_lm(budget, 2)
    assert {:error, {:rlm_max_llm_calls, 3}} = Budget.reserve_lm(budget, 2)
    assert {:ok, 3} = Budget.reserve_lm(budget, 1)

    assert {:ok, 1} = Budget.enter_recursion(budget, 0)
    assert {:ok, 2} = Budget.enter_recursion(budget, 1)
    assert {:error, {:rlm_max_recursion_depth, 2}} = Budget.enter_recursion(budget, 2)

    assert %{lm_calls: 3, max_recursion_depth_reached: 2} = Budget.snapshot(budget)
  end

  test "sibling recursion depth is branch scoped" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1, max_recursion_depth: 1)

    assert {:ok, 1} = Budget.enter_recursion(budget, 0)
    assert {:ok, 1} = Budget.enter_recursion(budget, 0)
    assert {:error, {:rlm_max_recursion_depth, 1}} = Budget.enter_recursion(budget, 1)
  end

  test "LM leases reserve capacity and charge only committed calls" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 3)

    assert {:ok, lease} = Budget.lease_lm(budget, 3)
    assert {:error, {:rlm_max_llm_calls, 3}} = Budget.reserve_lm(budget, 1)
    assert {:ok, 1} = Budget.commit_lm(budget, lease)
    assert %{lm_calls: 1, reserved_lm_calls: 2} = Budget.snapshot(budget)
    assert :ok = Budget.release_lm(budget, lease)
    assert %{lm_calls: 1, reserved_lm_calls: 0} = Budget.snapshot(budget)
    assert {:ok, 3} = Budget.reserve_lm(budget, 2)
  end

  test "LM lease commit atomically rejects cancellation without consuming the lease" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 2)
    {:ok, lease} = Budget.lease_lm(budget, 2)

    assert :ok = Budget.cancel(budget, :caller_stopped)

    assert {:error, {:rlm_cancelled, :caller_stopped}} = Budget.commit_lm(budget, lease)
    assert %{lm_calls: 0, reserved_lm_calls: 2} = Budget.snapshot(budget)
  end

  test "LM lease commit atomically rejects an expired deadline without consuming the lease" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1, max_time_ms: 60_000)
    {:ok, lease} = Budget.lease_lm(budget, 1)

    :sys.replace_state(budget, fn state ->
      %{state | deadline: System.monotonic_time(:millisecond) - 1}
    end)

    assert {:error, :rlm_time_budget_exceeded} = Budget.commit_lm(budget, lease)
    assert %{lm_calls: 0, reserved_lm_calls: 1} = Budget.snapshot(budget)
  end

  test "cancellation is sticky and prevents new work" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1)

    assert :ok = Budget.cancel(budget, :caller_stopped)
    assert :ok = Budget.cancel(budget, :later_reason)
    assert {:error, {:rlm_cancelled, :caller_stopped}} = Budget.check(budget)
    assert {:error, {:rlm_cancelled, :caller_stopped}} = Budget.reserve_lm(budget, 1)
    assert %{cancelled: :caller_stopped} = Budget.snapshot(budget)
  end

  test "cancellation terminates registered in-flight effects" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1)
    effect = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(effect)

    assert :ok = Budget.register_effect(budget, effect)
    assert :ok = Budget.cancel(budget, :caller_stopped)
    assert_receive {:DOWN, ^monitor, :process, ^effect, :killed}, 500
  end

  test "an effect registered after cancellation is rejected and terminated" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1)
    assert :ok = Budget.cancel(budget, :caller_stopped)

    effect = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(effect)

    assert {:error, {:rlm_cancelled, :caller_stopped}} =
             Budget.register_effect(budget, effect)

    assert_receive {:DOWN, ^monitor, :process, ^effect, :killed}, 500
  end

  test "deadline is observable and enforced" do
    {:ok, budget} = Budget.start_link(max_lm_calls: 1, max_time_ms: 0)
    Process.sleep(2)

    assert {:error, :rlm_time_budget_exceeded} = Budget.check(budget)
    assert %{remaining_time_ms: 0} = Budget.snapshot(budget)
  end
end
