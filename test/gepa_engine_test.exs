defmodule DSEx.Optimizer.GEPA.EngineTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Adapter, Engine, EvaluationPolicy, Result, Stopper}

  defmodule FirstValidationOnly do
    @behaviour EvaluationPolicy
    def validation_ids(_valset, _state, _target), do: [0]
    def best_entry(entries), do: Enum.max_by(entries, & &1.validation.aggregate_score)
    def score(entry), do: entry.validation.aggregate_score
  end

  defmodule AdapterFixture do
    defstruct []
    @behaviour Adapter

    def evaluate(_adapter, batch, candidate, opts) do
      scores =
        Enum.map(batch, fn required ->
          if String.contains?(candidate.main, required), do: 1.0, else: 0.0
        end)

      trajectories =
        if Keyword.get(opts, :capture_traces, false) do
          %{main: Enum.map(batch, fn _ -> nil end)}
        else
          %{}
        end

      Result.new(scores, scores,
        trajectories: trajectories,
        side_information: %{main: Enum.reject(batch, &String.contains?(candidate.main, &1))},
        metadata: %{metric_calls: length(batch)}
      )
    end

    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(
        components,
        &{&1, Enum.map(result.side_information[&1], fn value -> %{feedback: value} end)}
      )
    end
  end

  defmodule MergeAdapterFixture do
    defstruct []
    @behaviour Adapter

    def evaluate(_adapter, batch, candidate, opts) do
      scores =
        Enum.map(batch, fn
          :planner -> if candidate.planner == "left planner", do: 1.0, else: 0.0
          :writer -> if candidate.writer == "right writer", do: 1.0, else: 0.0
          _tie -> 0.5
        end)

      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do:
            Map.new(candidate, fn {component, _} ->
              {component, List.duplicate(nil, length(batch))}
            end),
          else: %{}

      Result.new(scores, scores,
        trajectories: trajectories,
        side_information: Map.new(candidate, fn {component, _} -> {component, []} end),
        metadata: %{metric_calls: length(batch)}
      )
    end

    def make_reflective_dataset(_adapter, _candidate, _result, components),
      do: Map.new(components, &{&1, []})
  end

  test "accepts only strict minibatch improvements before full validation" do
    proposer = fn candidate, :main, records, _iteration ->
      additions = Enum.map_join(records, " ", & &1.feedback)
      String.trim(candidate.main <> " " <> additions)
    end

    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha", "beta"],
        ["alpha", "beta"],
        proposer,
        max_iterations: 2,
        minibatch_size: 2,
        seed: 4,
        max_metric_calls: 20
      )

    assert length(state.candidates) == 2
    assert length(state.rejected) == 1
    assert Engine.best(state).validation.aggregate_score == 1.0
    assert state.budget.metric_calls == 8
    assert state.budget.full_evaluations == 2
    assert state.budget.reflection_calls == 2
    assert Enum.map(state.history, & &1.status) == [:accepted, :rejected]
  end

  test "enforces observed call budget and stops before unauthorized work" do
    proposer = fn candidate, :main, records, _iteration ->
      candidate.main <> Enum.map_join(records, "", & &1.feedback)
    end

    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha", "beta"],
        ["alpha", "beta"],
        proposer,
        max_iterations: 3,
        minibatch_size: 2,
        max_metric_calls: 5
      )

    assert {:budget_exhausted, :metric_calls, 6, 5} = state.stop_reason
    assert state.budget.metric_calls == 4
    assert length(state.candidates) == 1
  end

  test "JSON checkpoint resume preserves RNG, cache, lineage, and budget" do
    proposer = fn candidate, :main, records, _iteration ->
      candidate.main <> " " <> Enum.map_join(records, " ", & &1.feedback)
    end

    receiver = self()

    assert_raise RuntimeError, "interrupt", fn ->
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha", "beta"],
        ["alpha", "beta"],
        proposer,
        max_iterations: 3,
        minibatch_size: 1,
        seed: 11,
        checkpoint_fn: fn checkpoint ->
          if checkpoint["iteration"] == 1 do
            send(receiver, {:checkpoint, checkpoint})
            raise "interrupt"
          end

          :ok
        end
      )
    end

    assert_receive {:checkpoint, checkpoint}
    checkpoint = checkpoint |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha", "beta"],
        ["alpha", "beta"],
        proposer,
        max_iterations: 3,
        minibatch_size: 1,
        resume_state: checkpoint
      )

    assert resumed.iteration == 3
    assert resumed.budget.metric_calls > 0
    assert Enum.all?(tl(resumed.candidates), &(&1.parent_ids != []))
    assert map_size(resumed.cache) > 0
  end

  test "scheduled common-ancestor merge runs before mutation and persists two-parent lineage" do
    root = %{planner: "base planner", writer: "base writer"}
    left = %{planner: "left planner", writer: "base writer"}
    right = %{planner: "base planner", writer: "right writer"}
    valset = [:planner, :writer, :tie_one, :tie_two, :tie_three]

    %Engine.State{} =
      initial =
      Engine.run(
        %MergeAdapterFixture{},
        root,
        [:planner],
        valset,
        fn _, _, _, _ -> flunk("zero iterations must not propose") end,
        max_iterations: 0
      )

    validation = fn candidate ->
      MergeAdapterFixture.evaluate(%MergeAdapterFixture{}, valset, candidate, [])
    end

    state = %Engine.State{
      initial
      | iteration: 2,
        candidates: [
          %Engine.Entry{id: 0, candidate: root, validation: validation.(root)},
          %Engine.Entry{
            id: 1,
            candidate: left,
            validation: validation.(left),
            parent_ids: [0]
          },
          %Engine.Entry{
            id: 2,
            candidate: right,
            validation: validation.(right),
            parent_ids: [0]
          }
        ],
        merge_due: 1,
        last_iteration_found_candidate: true
    }

    checkpoint = state |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    merged =
      Engine.run(
        %MergeAdapterFixture{},
        root,
        [:planner],
        valset,
        fn _, _, _, _ -> flunk("a scheduled merge must preempt reflective mutation") end,
        max_iterations: 3,
        use_merge: true,
        max_merge_invocations: 1,
        merge_val_overlap_floor: 5,
        resume_state: checkpoint
      )

    assert merged.iteration == 3
    assert merged.total_merges_tested == 1
    assert merged.merge_due == 0
    assert length(merged.candidates) == 4

    accepted = List.last(merged.candidates)
    assert accepted.parent_ids == [1, 2]
    assert accepted.candidate == %{planner: "left planner", writer: "right writer"}

    assert %{operation: :merge, status: :accepted, ancestor: 0, parent_ids: [1, 2]} =
             List.last(merged.history)
  end

  test "acceptance policy can admit an equal-scoring reflective candidate" do
    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "alpha"},
        ["alpha"],
        ["alpha"],
        fn candidate, :main, _records, _iteration -> candidate.main end,
        max_iterations: 1,
        acceptance_policy: :equal_or_better
      )

    assert length(state.candidates) == 2
    assert state.rejected == []
    assert List.last(state.history).acceptance == :equal_or_better
  end

  test "checkpointable stopper halts before proposer work" do
    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "alpha"},
        ["alpha"],
        ["alpha"],
        fn _, _, _, _ -> flunk("score threshold must stop before mutation") end,
        max_iterations: 5,
        stopper: Stopper.score_threshold(1.0)
      )

    assert state.iteration == 0
    assert state.stop_reason == {:stopper, [{:score_threshold, 1.0, 1.0}]}
    assert state.stopper_state != nil
    assert Engine.dump_state(state)["stopper_state"]["schema_version"] == 1
  end

  test "custom evaluation policy controls validation coverage and checkpoint identity" do
    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha"],
        ["alpha", "beta"],
        fn candidate, :main, records, _iteration ->
          candidate.main <> Enum.map_join(records, "", & &1.feedback)
        end,
        max_iterations: 1,
        evaluation_policy: FirstValidationOnly
      )

    assert Enum.all?(state.candidates, &(&1.validation.metadata.validation_ids == [0]))

    checkpoint = Engine.dump_state(state)
    assert checkpoint["evaluation_policy"] == Atom.to_string(FirstValidationOnly)

    assert_raise ArgumentError, ~r/evaluation policy mismatch/, fn ->
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha"],
        ["alpha", "beta"],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 1,
        resume_state: checkpoint
      )
    end
  end
end
