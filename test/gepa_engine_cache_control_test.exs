defmodule Imp.Optimizer.GEPA.EngineCacheControlTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.{Adapter, Callback, Engine, Result}

  defmodule TrackingAdapter do
    @behaviour Adapter
    defstruct [:owner]

    @impl true
    def evaluate(%__MODULE__{owner: owner}, batch, _candidate, opts) do
      capture_traces = Keyword.get(opts, :capture_traces, false)
      send(owner, {:evaluation, batch, capture_traces})

      Result.new(batch, List.duplicate(0.0, length(batch)),
        trajectories:
          if(capture_traces, do: %{main: List.duplicate(nil, length(batch))}, else: %{}),
        side_information: %{main: []},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, components),
      do: Map.new(components, &{&1, []})
  end

  defmodule TrackingCallback do
    @behaviour Callback

    @impl true
    def on_evaluation_start(event, owner), do: send(owner, {:evaluation_start, event})

    @impl true
    def on_evaluation_end(event, owner), do: send(owner, {:evaluation_end, event})

    @impl true
    def on_evaluation_skipped(event, owner), do: send(owner, {:evaluation_skipped, event})
  end

  test "repeated non-trace evaluations use the cache by default" do
    state = run_engine()

    assert_received {:evaluation, [:same], false}
    assert_received {:evaluation, [:same], true}
    refute_received {:evaluation, [:same], _capture_traces}

    assert_received {:evaluation_start, %{capture_traces: false}}

    assert_received {:evaluation_skipped, %{reason: :cache_hit, scores: [score]}}
    assert score == 0.0
    assert state.budget.metric_calls == 2
    assert state.budget.full_evaluations == 1
    assert map_size(state.cache) == 1
  end

  test "cache_evaluation false re-evaluates repeated non-trace work with normal accounting" do
    state = run_engine(cache_evaluation: false)

    assert_received {:evaluation, [:same], false}
    assert_received {:evaluation, [:same], true}
    assert_received {:evaluation, [:same], false}
    refute_received {:evaluation, [:same], _capture_traces}

    assert_received {:evaluation_start, %{capture_traces: false}}
    assert_received {:evaluation_end, %{scores: [score]}}
    assert score == 0.0
    refute_received {:evaluation_skipped, _}

    assert state.budget.metric_calls == 3
    assert state.budget.full_evaluations == 1
    assert map_size(state.cache) == 0
  end

  test "disabled cache mode accepts JSON dump/resume state" do
    initial = run_engine(cache_evaluation: false, max_iterations: 0)
    checkpoint = initial |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    resumed =
      run_engine(
        cache_evaluation: false,
        max_iterations: 1,
        resume_state: checkpoint
      )

    assert resumed.iteration == 1
    assert resumed.budget.metric_calls == 3
  end

  defmodule KilledRowAdapter do
    @behaviour Adapter
    defstruct [:owner]

    @impl true
    def evaluate(%__MODULE__{owner: owner}, batch, _candidate, opts) do
      capture_traces = Keyword.get(opts, :capture_traces, false)
      send(owner, {:evaluation, batch, capture_traces})

      Result.new(batch, List.duplicate(0.0, length(batch)),
        trajectories:
          if(capture_traces, do: %{main: List.duplicate(nil, length(batch))}, else: %{}),
        side_information: %{main: []},
        metadata: %{
          metric_calls: length(batch),
          failures: length(batch),
          killed: length(batch)
        }
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, components),
      do: Map.new(components, &{&1, []})
  end

  test "evaluations with killed rows proceed but are never cached or checkpointed" do
    state =
      Engine.run(
        %KilledRowAdapter{owner: self()},
        %{main: "same"},
        [:same],
        [:same],
        fn candidate, :main, [], _iteration -> candidate.main end,
        max_iterations: 1,
        minibatch_size: 1,
        callbacks: [{TrackingCallback, self()}]
      )

    # The run completed (kills do not abort or reject), but nothing with
    # killed rows entered the cache, so a resumed run must re-evaluate.
    refute_received {:evaluation_skipped, %{reason: :cache_hit}}
    assert map_size(state.cache) == 0

    checkpoint = state |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()
    assert checkpoint["cache"] == []
  end

  test "resume fails closed when the checkpoint cache identity does not match" do
    initial = run_engine(max_iterations: 0, cache_identity: %{model: "gpt-5.4-mini", temp: 1.0})
    checkpoint = initial |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    # Same identity resumes.
    resumed =
      run_engine(
        max_iterations: 1,
        cache_identity: %{model: "gpt-5.4-mini", temp: 1.0},
        resume_state: checkpoint
      )

    assert resumed.iteration == 1

    # A different configuration must not replay the checkpointed cache.
    assert_raise ArgumentError, ~r/cache identity does not match/, fn ->
      run_engine(
        max_iterations: 1,
        cache_identity: %{model: "some-other-model", temp: 0.0},
        resume_state: checkpoint
      )
    end

    # Dropping the identity entirely is also a mismatch (fail closed).
    assert_raise ArgumentError, ~r/cache identity does not match/, fn ->
      run_engine(max_iterations: 1, resume_state: checkpoint)
    end
  end

  test "disk cache partitions by identity so config changes cannot replay stale entries" do
    run_dir = Path.join(System.tmp_dir!(), "gepa-cache-identity-#{System.unique_integer([:positive])}")

    try do
      a = Imp.Optimizer.GEPA.EvaluationCache.Disk.new(run_dir: run_dir, identity: %{model: "a"})
      b = Imp.Optimizer.GEPA.EvaluationCache.Disk.new(run_dir: run_dir, identity: %{model: "b"})
      default = Imp.Optimizer.GEPA.EvaluationCache.Disk.new(run_dir: run_dir)

      roots = Enum.map([a, b, default], & &1.root)
      assert length(Enum.uniq(roots)) == 3
    after
      File.rm_rf(run_dir)
    end
  end

  test "cache_evaluation must be boolean" do
    assert_raise ArgumentError, ":cache_evaluation must be a boolean", fn ->
      run_engine(cache_evaluation: :memory)
    end
  end

  defp run_engine(opts \\ []) do
    Engine.run(
      %TrackingAdapter{owner: self()},
      %{main: "same"},
      [:same],
      [:same],
      fn candidate, :main, [], _iteration -> candidate.main end,
      Keyword.merge(
        [max_iterations: 1, minibatch_size: 1, callbacks: [{TrackingCallback, self()}]],
        opts
      )
    )
  end
end
