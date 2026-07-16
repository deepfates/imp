defmodule Imp.Optimize.Anything.ResultTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything.Result
  alias Imp.Optimizer.GEPA.{Budget, Engine}
  alias Imp.Optimizer.GEPA.Result, as: EvaluationResult

  test "projects candidates, lineage, frontiers, budget, and string best candidate" do
    state = %Engine.State{
      budget: %{
        Budget.new()
        | metric_calls: 7,
          full_evaluations: 2,
          reflection_calls: 1
      },
      rng_state: :rand.seed_s(:exsss, {1, 2, 3}),
      frontier_type: :hybrid,
      best_outputs_valset: %{heldout_a: [{1, %{answer: "better"}}]},
      stop_reason: :max_iterations,
      candidates: [
        entry(0, %{current_candidate: "base"}, [], [0.0, 1.0], 2),
        entry(1, %{current_candidate: "better"}, [0], [1.0, 1.0], 7)
      ]
    }

    result =
      Result.from_state(state,
        mode: :generalization,
        seed: 9,
        string_candidate_key: :current_candidate
      )

    assert Result.best_index(result) == 1
    assert Result.best_candidate(result) == "better"
    assert result.parents == [[], [0]]

    assert result.validation_subscores == [
             %{heldout_a: 0.0, heldout_b: 1.0},
             %{heldout_a: 1.0, heldout_b: 1.0}
           ]

    assert result.instance_frontier[{:instance, :heldout_a}] == [1]
    assert result.instance_frontier[{:instance, :heldout_b}] == [0, 1]
    assert result.total_metric_calls == 7
    assert result.full_evaluations == 2
    assert result.reflection_calls == 1
    assert result.best_outputs_valset == %{heldout_a: [{1, %{answer: "better"}}]}
    assert result.checkpoint["schema_version"] == 7
  end

  test "schema two round-trips through JSON" do
    state = %Engine.State{
      budget: Budget.new(),
      rng_state: :rand.seed_s(:exsss, {1, 2, 3}),
      best_outputs_valset: %{only: [{0, "base output"}]},
      candidates: [entry(0, %{main: "base"}, [], [1.0], 1)]
    }

    result = Result.from_state(state, mode: :single_task)
    encoded = Result.to_map(result)

    assert encoded["validation_schema_version"] == 2
    refute Map.has_key?(encoded, "__imp_type__")

    restored =
      encoded |> Jason.encode!() |> Jason.decode!() |> Result.from_map()

    assert restored.validation_scores == [1.0]
    assert restored.total_metric_calls == 0
    assert restored.mode == :single_task
    assert restored.best_outputs_valset == %{only: [{0, "base output"}]}
    assert restored.checkpoint["schema_version"] == 7
  end

  defp entry(id, candidate, parents, scores, discovered_at) do
    validation =
      EvaluationResult.new(List.duplicate(nil, length(scores)), scores,
        objective_scores: Enum.map(scores, &%{quality: &1}),
        metadata: %{validation_ids: [:heldout_a, :heldout_b] |> Enum.take(length(scores))}
      )

    %Engine.Entry{
      id: id,
      candidate: candidate,
      parent_ids: parents,
      validation: validation,
      discovered_at: discovered_at
    }
  end
end
