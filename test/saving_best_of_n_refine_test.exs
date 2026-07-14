defmodule SavingBestOfNRefineTest do
  use ExUnit.Case, async: true

  setup do
    metric = fn _example, _prediction -> true end
    feedback = fn _history -> "retry" end

    registry =
      DSEx.Saving.Registry.new(
        quality_metric: metric,
        retry_feedback: feedback
      )

    %{metric: metric, feedback: feedback, registry: registry}
  end

  test "BestOfN threshold and attempt count survive a JSON round-trip", context do
    restored =
      DSEx.predict("question -> answer")
      |> DSEx.Predict.BestOfN.new(context.metric,
        n: 7,
        threshold: 0.75,
        feedback_fn: context.feedback
      )
      |> json_round_trip(context.registry)

    assert %DSEx.Predict.BestOfN{n: 7, threshold: 0.75} = restored
    assert restored.metric == context.metric
    assert restored.feedback_fn == context.feedback
  end

  test "Refine nil threshold and attempt count survive a JSON round-trip", context do
    restored =
      DSEx.predict("question -> answer")
      |> DSEx.Predict.Refine.new(context.metric,
        max_attempts: 5,
        threshold: nil,
        fail_count: 2,
        feedback_fn: context.feedback
      )
      |> json_round_trip(context.registry)

    assert %DSEx.Predict.Refine{max_attempts: 5, threshold: nil, fail_count: 2} = restored
    assert restored.metric == context.metric
    assert restored.feedback_fn == context.feedback
  end

  test "callback predictor payloads require all current fields", context do
    best_state =
      DSEx.Predict.BestOfN.new(DSEx.predict("question -> answer"), context.metric, n: 2)
      |> DSEx.dump(registry: context.registry)
      |> Map.delete("threshold")

    refine_state =
      DSEx.Predict.Refine.new(DSEx.predict("question -> answer"), context.metric, max_attempts: 4)
      |> DSEx.dump(registry: context.registry)
      |> Map.drop(["threshold", "fail_count"])

    assert_raise ArgumentError, ~r/missing required keys: \["threshold"\]/, fn ->
      DSEx.load(best_state, registry: context.registry)
    end

    assert_raise ArgumentError, ~r/missing required keys: \["threshold", "fail_count"\]/, fn ->
      DSEx.load(refine_state, registry: context.registry)
    end
  end

  test "loading rejects invalid thresholds", context do
    for {program, label} <- [
          {DSEx.Predict.BestOfN.new(DSEx.predict("q -> a"), context.metric), "BestOfN threshold"},
          {DSEx.Predict.Refine.new(DSEx.predict("q -> a"), context.metric), "Refine threshold"}
        ] do
      state = DSEx.dump(program, registry: context.registry)

      assert_raise ArgumentError, ~r/saved #{label} must be a number or nil/, fn ->
        DSEx.load(Map.put(state, "threshold", "0.5"), registry: context.registry)
      end
    end
  end

  test "loading rejects invalid fail counts", context do
    state =
      DSEx.Predict.Refine.new(DSEx.predict("q -> a"), context.metric)
      |> DSEx.dump(registry: context.registry)

    assert_raise ArgumentError, ~r/saved Refine fail_count must be a non-negative integer/, fn ->
      DSEx.load(Map.put(state, "fail_count", -1), registry: context.registry)
    end
  end

  test "loading rejects invalid attempt counts", context do
    best_state =
      DSEx.Predict.BestOfN.new(DSEx.predict("q -> a"), context.metric)
      |> DSEx.dump(registry: context.registry)

    refine_state =
      DSEx.Predict.Refine.new(DSEx.predict("q -> a"), context.metric)
      |> DSEx.dump(registry: context.registry)

    assert_raise ArgumentError, ~r/saved BestOfN n must be a non-negative integer/, fn ->
      DSEx.load(Map.put(best_state, "n", 2.0), registry: context.registry)
    end

    assert_raise ArgumentError,
                 ~r/saved Refine max_attempts must be a non-negative integer/,
                 fn ->
                   DSEx.load(Map.put(refine_state, "max_attempts", -1),
                     registry: context.registry
                   )
                 end
  end

  defp json_round_trip(program, registry) do
    program
    |> DSEx.dump(registry: registry)
    |> Jason.encode!()
    |> Jason.decode!()
    |> DSEx.load(registry: registry)
  end
end
