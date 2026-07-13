defmodule DSEx.Optimizer.GEPA.BudgetTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Budget, BudgetLedger}

  test "authorizes capacity separately from recording observed metric work" do
    budget = Budget.new(max_metric_calls: 5, max_full_evaluations: 2)

    assert :ok = Budget.authorize_evaluation(budget, 5, :full)
    assert budget.metric_calls == 0

    assert {:ok, budget} = Budget.record_evaluation(budget, 3, :full)
    assert budget.metric_calls == 3
    assert budget.full_evaluations == 1

    assert {:ok, budget} = Budget.record_evaluation(budget, 2, :minibatch)
    assert budget.metric_calls == 5
    assert budget.full_evaluations == 1
  end

  test "rejects work atomically when either limit would be exceeded" do
    budget = Budget.new(max_metric_calls: 4, max_full_evaluations: 1)
    assert {:ok, budget} = Budget.record_evaluation(budget, 2, :full)

    assert {:error, {:budget_exhausted, :metric_calls, 5, 4}, same_budget} =
             Budget.record_evaluation(budget, 3, :minibatch)

    assert same_budget == budget

    assert {:error, {:budget_exhausted, :full_evaluations, 2, 1}, same_budget} =
             Budget.record_evaluation(budget, 1, :full)

    assert same_budget == budget
  end

  test "round-trips counts and limits through checkpoint-safe data" do
    budget = Budget.new(max_metric_calls: 9, max_full_evaluations: :infinity)
    assert {:ok, budget} = Budget.record_evaluation(budget, 4, :full)
    budget = Budget.record_reflection(budget)

    assert budget == budget |> Budget.dump() |> Budget.load!()
  end

  test "rejects impossible restored counters" do
    state = %{
      "max_metric_calls" => 1,
      "max_full_evaluations" => 1,
      "metric_calls" => 2,
      "full_evaluations" => 1,
      "reflection_calls" => 0
    }

    assert_raise ArgumentError, ~r/metric_calls count 2 exceeds configured limit 1/, fn ->
      Budget.load!(state)
    end
  end

  test "ledger reserves aggregate capacity and commits actual work without overshoot" do
    budget =
      Budget.new(
        max_metric_calls: 4,
        max_full_evaluations: 1,
        max_reflection_calls: 2
      )

    ledger = BudgetLedger.new()

    assert {:ok, ledger} =
             BudgetLedger.reserve(ledger, budget, "parent:1", %{metric_calls: 2})

    assert {:ok, ledger} =
             BudgetLedger.reserve(ledger, budget, "reflection:1", %{reflection_calls: 2})

    assert {:error, {:budget_exhausted, :metric_calls, 5, 4}} =
             BudgetLedger.reserve(ledger, budget, "child:1", %{metric_calls: 3})

    {budget, ledger} =
      BudgetLedger.commit(ledger, budget, "parent:1", %{metric_calls: 1})

    {budget, ledger} =
      BudgetLedger.commit(ledger, budget, "reflection:1", %{reflection_calls: 2})

    assert budget.metric_calls == 1
    assert budget.reflection_calls == 2
    assert BudgetLedger.empty?(ledger)
    assert ledger == ledger |> BudgetLedger.dump() |> BudgetLedger.load!()
  end
end
