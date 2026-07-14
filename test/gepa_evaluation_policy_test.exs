defmodule Imp.Optimizer.GEPA.EvaluationPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.{Engine, EvaluationPolicy, Result}

  defmodule FirstOnly do
    @behaviour EvaluationPolicy

    @impl true
    def validation_ids(_valset, _state, _target), do: [0]

    @impl true
    def best_entry(entries), do: List.last(entries)

    @impl true
    def score(entry), do: entry.validation.aggregate_score
  end

  defmodule InvalidIds do
    @behaviour EvaluationPolicy
    def validation_ids(_valset, _state, _target), do: [0, 0]
    def best_entry(entries), do: hd(entries)
    def score(entry), do: entry.validation.aggregate_score
  end

  test "full policy evaluates every validation index and breaks score ties by coverage" do
    policy = EvaluationPolicy.resolve!(:full)
    assert EvaluationPolicy.validation_ids(policy, [:a, :b], nil, nil) == [0, 1]

    short = %Engine.Entry{id: 1, candidate: %{main: "short"}, validation: result([1.0])}
    full = %Engine.Entry{id: 2, candidate: %{main: "full"}, validation: result([1.0, 1.0])}
    assert policy.best_entry([short, full]) == full
  end

  test "custom behaviour modules resolve without callback wrappers" do
    assert EvaluationPolicy.resolve!(FirstOnly) == FirstOnly
    assert EvaluationPolicy.validation_ids(FirstOnly, [:a, :b], nil, 1) == [0]
  end

  test "invalid modules and validation indexes fail explicitly" do
    assert_raise ArgumentError, ~r/must implement/, fn ->
      EvaluationPolicy.resolve!(__MODULE__)
    end

    assert_raise ArgumentError, ~r/unique validation indexes/, fn ->
      EvaluationPolicy.validation_ids(InvalidIds, [:a], nil, nil)
    end
  end

  defp result(scores), do: Result.new(List.duplicate(nil, length(scores)), scores)
end
