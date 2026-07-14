defmodule Imp.Optimizer.GEPA.StopperTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.Stopper

  test "max metric calls and score threshold stop at inclusive limits" do
    policy = Stopper.any([Stopper.max_metric_calls(10), Stopper.score_threshold(0.9)])
    state = Stopper.new(policy, now: 0)

    assert {:continue, state} =
             Stopper.check(policy, state, %{metric_calls: 9, best_score: 0.89}, now: 0)

    assert {:stop, [{:max_metric_calls, 10, 10}], _state} =
             Stopper.check(policy, state, %{metric_calls: 10, best_score: 0.89}, now: 0)

    assert {:stop, [{:score_threshold, 0.9, 0.9}], _state} =
             Stopper.check(policy, state, %{metric_calls: 9, best_score: 0.9}, now: 0)
  end

  test "timeout uses injected monotonic time and survives checkpoint rebasing" do
    policy = Stopper.timeout(100)
    state = Stopper.new(policy, now: 1_000)

    assert {:continue, state} = Stopper.check(policy, state, %{}, now: 1_060)
    checkpoint = state |> Stopper.dump() |> Jason.encode!() |> Jason.decode!()

    state = Stopper.load!(checkpoint, now: 50_000)
    assert {:continue, state} = Stopper.check(policy, state, %{}, now: 50_039)

    assert {:stop, [{:timeout, 100, 100}], _state} =
             Stopper.check(policy, state, %{}, now: 50_040)
  end

  test "absolute deadline uses the same injected clock" do
    policy = Stopper.deadline(500)
    state = Stopper.new(policy, now: fn -> 100 end)

    assert {:continue, state} = Stopper.check(policy, state, %{}, now: fn -> 499 end)

    assert {:stop, [{:deadline, 500, 500}], _state} =
             Stopper.check(policy, state, %{}, now: fn -> 500 end)
  end

  test "no-improvement patience tracks strict best-score changes explicitly" do
    policy = Stopper.no_improvement(2)
    state = Stopper.new(policy, now: 0)

    assert {:continue, state} = Stopper.check(policy, state, %{best_score: 0.5}, now: 0)
    assert {:continue, state} = Stopper.check(policy, state, %{best_score: 0.5}, now: 0)

    assert {:continue, state} = Stopper.check(policy, state, %{best_score: 0.6}, now: 0)
    assert {:continue, state} = Stopper.check(policy, state, %{best_score: 0.59}, now: 0)

    assert {:stop, [{:no_improvement, 2, 2, 0.6}], stopped_state} =
             Stopper.check(policy, state, %{best_score: 0.6}, now: 0)

    assert stopped_state == stopped_state |> Stopper.dump() |> Stopper.load!(now: 10)
  end

  test "consecutive semantic outcomes count each completed iteration once and resume" do
    policy = Stopper.consecutive_outcome(:proposal_error, 3)
    state = Stopper.new(policy, now: 0)

    assert {:continue, state} =
             Stopper.check(
               policy,
               state,
               %{iteration: 1, semantic_outcome: :proposal_error},
               now: 0
             )

    assert {:continue, ^state} =
             Stopper.check(
               policy,
               state,
               %{iteration: 1, semantic_outcome: :proposal_error},
               now: 0
             )

    assert {:continue, state} =
             Stopper.check(
               policy,
               state,
               %{iteration: 2, semantic_outcome: :proposal_error},
               now: 0
             )

    checkpoint = state |> Stopper.dump() |> Jason.encode!() |> Jason.decode!()
    resumed = Stopper.load!(checkpoint, now: 10)

    assert {:stop, [{:consecutive_outcome, :proposal_error, 3, 3, 3}], _state} =
             Stopper.check(
               policy,
               resumed,
               %{iteration: 3, semantic_outcome: :proposal_error},
               now: 10
             )

    assert {:continue, _state} =
             Stopper.check(
               policy,
               resumed,
               %{iteration: 3, semantic_outcome: :accepted},
               now: 10
             )
  end

  test "file and manual callbacks are deterministic injected controls" do
    parent = self()

    file =
      Stopper.file("/run/gepa.stop",
        exists?: fn path ->
          send(parent, {:probed, path})
          path == "/run/gepa.stop"
        end
      )

    manual = Stopper.manual(fn context -> context[:command] || :continue end)

    assert {:stop, [{:file, "/run/gepa.stop"}], _state} =
             Stopper.check(file, Stopper.new(file, now: 0), %{}, now: 0)

    assert_receive {:probed, "/run/gepa.stop"}

    state = Stopper.new(manual, now: 0)
    assert {:continue, state} = Stopper.check(manual, state, %{}, now: 0)

    assert {:stop, [{:manual, :operator_requested}], _state} =
             Stopper.check(manual, state, %{command: {:stop, :operator_requested}}, now: 0)
  end

  test "all composition updates every child without short-circuiting" do
    policy = Stopper.all([Stopper.no_improvement(1), Stopper.timeout(10)])
    state = Stopper.new(policy, now: 0)

    assert {:continue, state} = Stopper.check(policy, state, %{best_score: 1.0}, now: 0)

    assert {:continue, state} =
             Stopper.check(policy, state, %{best_score: 1.0}, now: 5)

    assert {:stop,
            [
              {:no_improvement, 2, 1, 1.0},
              {:timeout, 10, 10}
            ], _state} = Stopper.check(policy, state, %{best_score: 1.0}, now: 10)
  end

  test "invalid policy context and corrupt checkpoints fail loudly" do
    policy = Stopper.max_metric_calls(1)
    state = Stopper.new(policy, now: 0)

    assert_raise ArgumentError, ~r/metric_calls.*non-negative integer/, fn ->
      Stopper.check(policy, state, %{}, now: 0)
    end

    assert_raise ArgumentError, ~r/invalid GEPA stopper checkpoint/, fn ->
      Stopper.load!(%{"schema_version" => 2, "nodes" => []}, now: 0)
    end
  end
end
