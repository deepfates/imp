defmodule SavingBestOfNRefineTest do
  use ExUnit.Case, async: true

  setup do
    metric = fn _example, _prediction -> true end
    feedback = fn _history -> "retry" end

    registry =
      Imp.Saving.Registry.new(
        quality_metric: metric,
        retry_feedback: feedback
      )

    %{metric: metric, feedback: feedback, registry: registry}
  end

  test "BestOfN threshold and attempt count survive a JSON round-trip", context do
    restored =
      Imp.predict("question -> answer")
      |> Imp.Predict.BestOfN.new(context.metric,
        n: 7,
        threshold: 0.75,
        feedback_fn: context.feedback
      )
      |> json_round_trip(context.registry)

    assert %Imp.Predict.BestOfN{n: 7, threshold: 0.75} = restored
    assert restored.metric == context.metric
    assert restored.feedback_fn == context.feedback
  end

  test "Refine nil threshold and attempt count survive a JSON round-trip", context do
    restored =
      Imp.predict("question -> answer")
      |> Imp.Predict.Refine.new(context.metric,
        n: 5,
        threshold: nil,
        fail_count: 2,
        feedback_fn: context.feedback
      )
      |> json_round_trip(context.registry)

    assert %Imp.Predict.Refine{n: 5, threshold: nil, fail_count: 2} = restored
    assert restored.metric == context.metric
    assert restored.feedback_fn == context.feedback
  end

  test "a Refine saved with its attempt count under the pre-0.5.0 key loads", context do
    state =
      Imp.predict("question -> answer")
      |> Imp.Predict.Refine.new(context.metric, n: 4)
      |> Imp.Saving.dump(registry: context.registry)

    assert state["n"] == 4
    old = state |> Map.delete("n") |> Map.put("max_attempts", 4)

    assert %Imp.Predict.Refine{n: 4} =
             old
             |> Jason.encode!()
             |> Jason.decode!()
             |> Imp.Saving.load!(registry: context.registry)
  end

  test "callback predictor payloads require all current fields", context do
    best_state =
      Imp.Predict.BestOfN.new(Imp.predict("question -> answer"), context.metric, n: 2)
      |> Imp.dump(registry: context.registry)
      |> Map.delete("threshold")

    refine_state =
      Imp.Predict.Refine.new(Imp.predict("question -> answer"), context.metric, n: 4)
      |> Imp.dump(registry: context.registry)
      |> Map.drop(["threshold", "fail_count"])

    assert_raise ArgumentError, ~r/missing required keys: \["threshold"\]/, fn ->
      Imp.load!(best_state, registry: context.registry)
    end

    assert_raise ArgumentError, ~r/missing required keys: \["threshold", "fail_count"\]/, fn ->
      Imp.load!(refine_state, registry: context.registry)
    end
  end

  test "loading rejects invalid thresholds", context do
    for {program, label} <- [
          {Imp.Predict.BestOfN.new(Imp.predict("q -> a"), context.metric), "BestOfN threshold"},
          {Imp.Predict.Refine.new(Imp.predict("q -> a"), context.metric), "Refine threshold"}
        ] do
      state = Imp.dump(program, registry: context.registry)

      assert_raise ArgumentError, ~r/saved #{label} must be a number or nil/, fn ->
        Imp.load!(Map.put(state, "threshold", "0.5"), registry: context.registry)
      end
    end
  end

  test "loading rejects invalid fail counts", context do
    state =
      Imp.Predict.Refine.new(Imp.predict("q -> a"), context.metric)
      |> Imp.dump(registry: context.registry)

    assert_raise ArgumentError, ~r/saved Refine fail_count must be a non-negative integer/, fn ->
      Imp.load!(Map.put(state, "fail_count", -1), registry: context.registry)
    end
  end

  test "loading rejects invalid attempt counts", context do
    best_state =
      Imp.Predict.BestOfN.new(Imp.predict("q -> a"), context.metric)
      |> Imp.dump(registry: context.registry)

    refine_state =
      Imp.Predict.Refine.new(Imp.predict("q -> a"), context.metric)
      |> Imp.dump(registry: context.registry)

    assert_raise ArgumentError, ~r/saved BestOfN n must be a non-negative integer/, fn ->
      Imp.load!(Map.put(best_state, "n", 2.0), registry: context.registry)
    end

    assert_raise ArgumentError, ~r/saved Refine n must be a non-negative integer/, fn ->
      Imp.load!(Map.put(refine_state, "n", -1), registry: context.registry)
    end

    old_key = refine_state |> Map.delete("n") |> Map.put("max_attempts", -1)

    assert_raise ArgumentError, ~r/saved Refine n must be a non-negative integer/, fn ->
      Imp.load!(old_key, registry: context.registry)
    end
  end

  defp json_round_trip(program, registry) do
    program
    |> Imp.dump(registry: registry)
    |> Jason.encode!()
    |> Jason.decode!()
    |> Imp.load!(registry: registry)
  end
end
