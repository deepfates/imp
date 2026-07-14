defmodule DSEx.Optimizer.GEPA.ComBeeTest do
  use ExUnit.Case, async: false

  alias DSEx.Optimizer.GEPA.{Adapter, ComBee, Engine, Result}
  alias DSEx.Optimizer.GEPA.ComBee.BatchController

  defmodule FixtureAdapter do
    @behaviour Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      score = if candidate.main == "base", do: 0.0, else: 1.0

      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Result.new(batch, List.duplicate(score, length(batch)),
        trajectories: trajectories,
        side_information: %{main: batch},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        {component, Enum.map(result.outputs, &%{id: &1})}
      end)
    end
  end

  defmodule RecordingCallback do
    @behaviour DSEx.Optimizer.GEPA.Callback

    @impl true
    def on_combee_aggregation(event, owner),
      do: send(owner, {:aggregation_callback, event.iteration, event.component, event.report})
  end

  test "augmented shuffle duplicates every source and builds a deterministic sqrt tree" do
    records = Enum.map(0..16, &%{id: &1})
    policy = policy(17, seed: 42, duplication_factor: 2, max_concurrency: 4)
    plan = ComBee.plan(records, :main, 3, policy)

    assert plan.source_count == 17
    assert plan.augmented_count == 34
    assert plan.group_count == 4
    assert Enum.map(plan.groups, & &1.size) == [9, 9, 8, 8]
    assert plan == ComBee.plan(records, :main, 3, policy)
    refute plan == ComBee.plan(records, :main, 4, policy)

    copies =
      plan.groups
      |> Enum.flat_map(& &1.entries)
      |> Enum.group_by(& &1.source_index, & &1.duplicate_index)

    assert Map.keys(copies) == Enum.to_list(0..16)
    assert Enum.all?(copies, fn {_source, duplicates} -> Enum.sort(duplicates) == [0, 1] end)
  end

  test "first-level calls overlap while final reduction remains in group order" do
    owner = self()
    candidate = %{main: "current", untouched: "keep"}
    records = Enum.map(0..15, &%{id: &1})
    policy = policy(16, seed: 9, max_concurrency: 4)

    proposer = fn received_candidate, component, received_records, iteration, metadata ->
      send(
        owner,
        {:call, metadata.phase, metadata[:group_index], received_candidate, component, iteration,
         received_records, self()}
      )

      case metadata.phase do
        :first_level ->
          Process.sleep((3 - metadata.group_index) * 10)
          "group-#{metadata.group_index}"

        :final ->
          Enum.map_join(received_records, "|", & &1["ComBeeIntermediateUpdate"])
      end
    end

    assert {:ok, "group-0|group-1|group-2|group-3", report} =
             ComBee.aggregate(proposer, candidate, :main, records, 7, policy)

    assert report.status == :ok
    assert report.first_level_calls == 4
    assert report.final_calls == 1
    assert report.reflection_calls == 5

    calls = receive_calls(5, [])
    first_level = Enum.filter(calls, &(elem(&1, 1) == :first_level))
    final = Enum.find(calls, &(elem(&1, 1) == :final))

    assert first_level |> Enum.map(&elem(&1, 7)) |> Enum.uniq() |> length() == 4
    assert Enum.all?(calls, &(elem(&1, 3) == candidate))
    assert Enum.all?(calls, &(elem(&1, 4) == :main))
    assert elem(final, 6) |> Enum.map(& &1["ComBeeGroupIndex"]) == [0, 1, 2, 3]
  end

  test "production fallback retains more than 64 first-level and final aggregation inputs" do
    records = Enum.map(0..79, &%{"Feedback" => "source-#{&1}"})

    first =
      DSEx.Optimizer.GEPA.fallback_proposal(
        %{main: "current"},
        :main,
        records,
        1,
        "",
        %{phase: :first_level}
      )

    final_records =
      Enum.map(0..79, &%{"ComBeeIntermediateUpdate" => "intermediate-#{&1}"})

    final =
      DSEx.Optimizer.GEPA.fallback_proposal(
        %{main: "current"},
        :main,
        final_records,
        1,
        "",
        %{phase: :final}
      )

    assert Enum.all?(0..79, &String.contains?(first, "source-#{&1}"))
    assert Enum.all?(0..79, &String.contains?(final, "intermediate-#{&1}"))
  end

  test "one deadline covers queued first-level work and the final level" do
    owner = self()
    records = Enum.map(0..15, &%{id: &1})
    policy = policy(16, max_concurrency: 1, timeout: 25)

    proposer = fn _candidate, _component, _records, _iteration, metadata ->
      send(owner, {:deadline_call, metadata.phase, metadata[:group_index]})
      Process.sleep(if(metadata.group_index == 0, do: 1, else: 50))
      "update-#{metadata[:group_index]}"
    end

    started = System.monotonic_time(:millisecond)

    assert {:error, {:combee_first_level_failed, 1, :timeout}, report} =
             ComBee.aggregate(proposer, %{main: "current"}, :main, records, 1, policy)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 75
    assert report.first_level_calls == 2
    assert report.final_calls == 0
    assert report.reflection_calls == 2
    assert receive_deadline_calls([]) == [{:first_level, 0}, {:first_level, 1}]
  end

  test "one proposal deadline is inherited across sequential components" do
    owner = self()
    policy = policy(1, max_concurrency: 1, timeout: :infinity)

    proposer = fn _candidate, component, _records, _iteration, metadata ->
      send(owner, {:proposal_deadline_call, component, metadata.phase})
      delay = if component == :alpha, do: 6, else: if(metadata.phase == :final, do: 20, else: 1)
      Process.sleep(delay)
      "update-#{metadata.phase}"
    end

    parent = %{candidate: %{alpha: "a", beta: "b"}}

    context = %{
      components: [:alpha, :beta],
      dataset: %{alpha: [%{id: 1}], beta: [%{id: 2}]},
      iteration: 1
    }

    started = System.monotonic_time(:millisecond)

    assert [{:error, :timeout}] =
             DSEx.Optimizer.GEPA.Coordinator.run([:proposal], 25, fn :proposal ->
               DSEx.Optimizer.GEPA.Reflection.execute(proposer, parent, context, policy)
             end)

    assert System.monotonic_time(:millisecond) - started < 60

    calls = receive_proposal_deadline_calls([])

    assert calls != []

    assert calls ==
             Enum.take(
               [
                 {:alpha, :first_level},
                 {:alpha, :final},
                 {:beta, :first_level},
                 {:beta, :final}
               ],
               length(calls)
             )
  end

  test "terminal failure stops queued dispatch and cancels active siblings" do
    owner = self()
    baseline = MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor))
    records = Enum.map(0..24, &%{id: &1})
    policy = policy(25, max_concurrency: 2, timeout: 1_000)

    proposer = fn _candidate, _component, _records, _iteration, metadata ->
      send(owner, {:fail_fast_call, metadata.group_index, self()})

      case metadata.group_index do
        0 ->
          Process.sleep(15)
          Process.exit(self(), :kill)

        1 ->
          Process.sleep(:infinity)

        index ->
          "must-not-dispatch-#{index}"
      end
    end

    assert {:error, {:combee_first_level_failed, 0, {:worker_exit, :killed}}, report} =
             ComBee.aggregate(proposer, %{main: "current"}, :main, records, 1, policy)

    assert report.first_level_calls == 2
    assert report.reflection_calls == 2
    assert_receive {:fail_fast_call, 0, _worker_zero}
    assert_receive {:fail_fast_call, 1, worker_one}
    refute_receive {:fail_fast_call, 2, _worker}
    refute_receive {:fail_fast_call, 3, _worker}
    refute_receive {:fail_fast_call, 4, _worker}

    assert eventually(fn ->
             not Process.alive?(worker_one) and
               MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)) == baseline
           end)
  end

  test "fatal exits and timeouts fail deterministically without task leaks" do
    baseline = MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor))
    records = Enum.map(0..8, &%{id: &1})
    crash_policy = policy(9, max_concurrency: 3, timeout: 100)

    crashing = fn _candidate, _component, _records, _iteration, metadata ->
      if metadata.phase == :first_level and metadata.group_index == 0,
        do: Process.exit(self(), :kill),
        else: "ok-#{metadata[:group_index]}"
    end

    assert {:error, {:combee_first_level_failed, 0, {:worker_exit, :killed}}, report} =
             ComBee.aggregate(crashing, %{main: "current"}, :main, records, 1, crash_policy)

    assert report.reflection_calls == 3
    assert report.final_calls == 0

    timeout_policy = policy(9, max_concurrency: 3, timeout: 15)

    timing_out = fn _candidate, _component, _records, _iteration, metadata ->
      if metadata.phase == :first_level and metadata.group_index == 0,
        do: Process.sleep(:infinity),
        else: "ok-#{metadata[:group_index]}"
    end

    assert {:error, {:combee_first_level_failed, 0, :timeout}, timeout_report} =
             ComBee.aggregate(timing_out, %{main: "current"}, :main, records, 1, timeout_policy)

    assert timeout_report.reflection_calls == 3

    assert eventually(fn ->
             MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)) == baseline
           end)
  end

  test "caller cancellation terminates nested aggregation workers" do
    baseline = MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor))
    owner = self()
    policy = policy(9, max_concurrency: 3, timeout: :infinity)

    caller =
      spawn(fn ->
        proposer = fn _candidate, _component, _records, _iteration, metadata ->
          if metadata.phase == :first_level do
            send(owner, {:combee_worker, self()})
            Process.sleep(:infinity)
          end

          "unused"
        end

        ComBee.aggregate(
          proposer,
          %{main: "current"},
          :main,
          Enum.map(0..8, &%{id: &1}),
          1,
          policy
        )
      end)

    workers = for _ <- 1..3, do: receive(do: ({:combee_worker, worker} -> worker))
    Process.exit(caller, :kill)

    assert eventually(fn ->
             Enum.all?(workers, &(not Process.alive?(&1))) and
               MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)) == baseline
           end)
  end

  test "reflection budget preauthorizes the whole tree and stops exactly" do
    owner = self()
    proposer = recording_proposer(owner)
    trainset = Enum.to_list(0..15)
    combee = [duplication_factor: 2, max_concurrency: 4]

    refused =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        trainset,
        [:validation],
        proposer,
        max_iterations: 1,
        minibatch_size: 16,
        combee: combee,
        max_reflection_calls: 4
      )

    assert refused.stop_reason == {:budget_exhausted, :reflection_calls, 5, 4}
    assert refused.budget.reflection_calls == 0
    refute_receive {:model_call, _, _}

    exact =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        trainset,
        [:validation],
        proposer,
        max_iterations: 1,
        minibatch_size: 16,
        combee: combee,
        max_reflection_calls: 5
      )

    assert exact.budget.reflection_calls == 5
    assert length(exact.candidates) == 2
    assert length(exact.combee_reports) == 1
    assert exact.combee_reports |> hd() |> Map.fetch!(:reflection_calls) == 5

    assert receive_model_calls(5, []) |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [
             :final,
             :first_level,
             :first_level,
             :first_level,
             :first_level
           ]
  end

  test "power-law fit uses epoch delay, paper tau ratio, clamp, and fail-closed status" do
    report =
      BatchController.select(
        [
          measurements: [{1, 10.0}, {4, 20.0}, {9, 30.0}],
          max_batch_size: 12
        ],
        100
      )

    assert report.status == :ok
    assert report.measurement_source == :caller_supplied
    assert_in_delta report.a, 1000.0, 1.0e-8
    assert_in_delta report.alpha, 0.5, 1.0e-8
    assert_in_delta report.tau, report.peak_slope * 0.016, 1.0e-8
    assert report.plateau_batch_size > 12
    assert report.selected_batch_size == 12

    degenerate =
      BatchController.select(
        [measurements: [{2, 5.0}, {2, 6.0}], min_batch_size: 2, max_batch_size: 20],
        100
      )

    assert degenerate.status == :degenerate
    assert degenerate.reason == :duplicate_batch_sizes
    assert degenerate.selected_batch_size == 2
    assert degenerate.a == nil

    assert_raise ArgumentError, ~r/max_batch_size/, fn ->
      BatchController.options!(max_batch_size: 201)
    end

    assert_raise ArgumentError, ~r/offline measurement fitting requires/, fn ->
      BatchController.select([], 100)
    end

    assert %BatchController.Options{mode: :runtime} =
             ComBee.Options.new!(batch_controller: true).batch_controller
  end

  test "checkpoint identity rejects ComBee policy and controller drift" do
    base_options = [
      duplication_factor: 2,
      max_concurrency: 2,
      batch_controller: [measurements: [{1, 4.0}, {2, 5.0}], max_batch_size: 2]
    ]

    checkpoint =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        [0, 1],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        combee: base_options
      )
      |> Engine.dump_state()
      |> json_round_trip()

    assert checkpoint["schema_version"] == 4
    assert checkpoint["combee_policy"]["effective_batch_size"] == 2

    resumed =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        [0, 1],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        combee: base_options,
        resume_state: checkpoint
      )

    assert resumed.combee_policy.identity == checkpoint["combee_policy"]["identity"]

    assert_raise ArgumentError, ~r/ComBee policy mismatch/, fn ->
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        [0, 1],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        combee: Keyword.put(base_options, :duplication_factor, 3),
        resume_state: checkpoint
      )
    end

    legacy_policy =
      checkpoint["combee_policy"]
      |> update_in(["batch_controller_options"], fn options ->
        Map.drop(options, ["mode", "candidate_batch_sizes", "profiling_timeout"])
      end)
      |> update_in(["batch_controller"], fn report ->
        Map.drop(report, [
          "mode",
          "candidate_batch_sizes",
          "trials",
          "current_trial",
          "elapsed_ms",
          "metric_calls",
          "reflection_calls",
          "profiling_timeout",
          "identity"
        ])
      end)

    migrated = ComBee.load_policy!(legacy_policy)
    assert migrated.identity == checkpoint["combee_policy"]["identity"]
    assert migrated.batch_controller.mode == :offline_measurements
    assert is_binary(migrated.batch_controller.identity)
  end

  test "ComBee composes with bounded speculative proposals and rejects oversubscription" do
    DSEx.Settings.context([async_max_workers: 4], fn ->
      state =
        Engine.run(
          %FixtureAdapter{},
          %{main: "base"},
          Enum.to_list(0..7),
          [:validation],
          fn _candidate, _component, records, iteration, metadata ->
            if metadata.phase == :final do
              "proposal-#{iteration}"
            else
              "local-#{metadata.group_index}-#{length(records)}"
            end
          end,
          max_iterations: 2,
          minibatch_size: 4,
          proposal_concurrency: 2,
          candidate_selection_strategy: :current_best,
          acceptance_policy: :equal_or_better,
          combee: [max_concurrency: 2],
          max_reflection_calls: 6
        )

      assert state.iteration == 2
      assert state.budget.reflection_calls == 6
      assert state.combee_policy.max_concurrency == 2
      assert Enum.map(state.combee_reports, & &1.iteration) == [1, 2]

      assert_raise ArgumentError, ~r/exceeds async_max_workers/, fn ->
        Engine.run(
          %FixtureAdapter{},
          %{main: "base"},
          Enum.to_list(0..7),
          [:validation],
          fn _, _, _, _ -> "unused" end,
          max_iterations: 0,
          minibatch_size: 4,
          proposal_concurrency: 2,
          combee: [max_concurrency: 3]
        )
      end
    end)
  end

  test "public options and callback metadata expose ComBee reports" do
    owner = self()

    metric = fn _example, _prediction -> 1.0 end

    assert %DSEx.Optimizer.GEPA{
             combee: %ComBee.Options{duplication_factor: 2},
             max_reflection_calls: 5
           } =
             DSEx.Optimizer.GEPA.new(metric,
               combee: true,
               max_reflection_calls: 5
             )

    Engine.run(
      %FixtureAdapter{},
      %{main: "base"},
      Enum.to_list(0..3),
      [:validation],
      recording_proposer(owner),
      max_iterations: 1,
      minibatch_size: 4,
      combee: [max_concurrency: 2],
      callbacks: [{RecordingCallback, owner}]
    )

    assert_receive {:aggregation_callback, 1, :main, %ComBee.Report{status: :ok}}
  end

  test "runtime controller executes synchronized trials as budgeted GEPA iterations" do
    owner = self()

    state =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        Enum.to_list(0..7),
        [:validation],
        fn _candidate, _component, _records, iteration, metadata ->
          send(owner, {:runtime_trial_call, iteration, metadata.phase, metadata[:source_count]})
          Process.sleep(2)

          if metadata.phase == :final,
            do: "improved-#{iteration}",
            else: "local-#{iteration}-#{metadata.group_index}"
        end,
        max_iterations: 2,
        minibatch_size: 1,
        candidate_selection_strategy: :current_best,
        acceptance_policy: :equal_or_better,
        combee: [
          max_concurrency: 2,
          batch_controller: [
            mode: :runtime,
            candidate_batch_sizes: [2, 4],
            max_batch_size: 4,
            profiling_timeout: 2_000
          ]
        ],
        max_reflection_calls: 5
      )

    report = state.combee_policy.batch_controller
    assert state.iteration == 2
    assert report.status in [:ok, :degenerate], inspect(report, limit: :infinity)
    assert report.measurement_source == :runtime_trials

    assert Enum.map(report.trials, &{&1.index, &1.iteration, &1.batch_size, &1.status}) == [
             {0, 1, 2, :ok},
             {1, 2, 4, :ok}
           ]

    assert Enum.map(report.measurements, &elem(&1, 0)) == [2, 4]
    assert report.reflection_calls == 5
    assert report.metric_calls == state.budget.metric_calls - 1
    assert state.budget.reflection_calls == 5

    calls = receive_runtime_trial_calls([])
    assert calls |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [1, 2]
    assert Enum.all?(Enum.filter(calls, &(elem(&1, 1) == 1)), &(elem(&1, 3) == 2))
    assert Enum.all?(Enum.filter(calls, &(elem(&1, 1) == 2)), &(elem(&1, 3) == 4))
  end

  test "runtime profiling records clean budget refusal and never fits the failed trial" do
    state =
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        Enum.to_list(0..7),
        [:validation],
        fn _candidate, _component, _records, iteration, metadata ->
          if metadata.phase == :final,
            do: "improved-#{iteration}",
            else: "local-#{metadata.group_index}"
        end,
        max_iterations: 2,
        candidate_selection_strategy: :current_best,
        acceptance_policy: :equal_or_better,
        combee: [
          max_concurrency: 2,
          batch_controller: [candidate_batch_sizes: [2, 4], max_batch_size: 4]
        ],
        max_reflection_calls: 4
      )

    report = state.combee_policy.batch_controller
    assert report.status == :incomplete
    assert report.reason == {:budget_exhausted, :reflection_calls, 5, 4}
    assert Enum.map(report.trials, & &1.status) == [:ok, :error]
    assert Enum.map(report.measurements, &elem(&1, 0)) == [2]
    assert report.metric_calls == state.budget.metric_calls - 1
    assert report.reflection_calls == state.budget.reflection_calls
    assert report.selected_batch_size == 1
  end

  test "runtime profiling timeout is one deadline across trial checkpoint overhead" do
    owner = self()

    assert_raise RuntimeError, ~r/interrupt after profiling timeout/, fn ->
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        Enum.to_list(0..7),
        [:validation],
        fn _candidate, _component, _records, iteration, metadata ->
          send(owner, {:profile_deadline_call, iteration, metadata.phase})
          if metadata.phase == :final, do: "improved", else: "local"
        end,
        max_iterations: 2,
        candidate_selection_strategy: :current_best,
        acceptance_policy: :equal_or_better,
        combee: [
          max_concurrency: 1,
          batch_controller: [
            candidate_batch_sizes: [2, 4],
            max_batch_size: 4,
            profiling_timeout: 35
          ]
        ],
        checkpoint_fn: fn checkpoint ->
          report = get_in(checkpoint, ["combee_policy", "batch_controller"])

          if report && length(report["trials"] || []) == 1 &&
               get_in(report, ["status", "value"]) == "profiling" do
            Process.sleep(40)
          end

          if checkpoint["stop_reason"] ==
               %{"__dsex_type__" => "atom", "value" => "profiling_timeout"} do
            raise "interrupt after profiling timeout"
          end

          :ok
        end
      )
    end

    calls = receive_profile_deadline_calls([])
    assert calls != []
    assert Enum.all?(calls, &(elem(&1, 1) == 1))
  end

  test "started profiling checkpoints are identity-bound and fail closed on resume" do
    owner = self()

    assert_raise RuntimeError, ~r/ambiguous provider effects/, fn ->
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        Enum.to_list(0..3),
        [:validation],
        fn _candidate, _component, _records, _iteration, _metadata ->
          Process.sleep(:infinity)
        end,
        max_iterations: 2,
        combee: [
          max_concurrency: 1,
          batch_controller: [
            candidate_batch_sizes: [2, 4],
            max_batch_size: 4,
            profiling_timeout: 25
          ]
        ],
        checkpoint_fn: fn checkpoint ->
          send(owner, {:runtime_checkpoint, checkpoint})
          :ok
        end
      )
    end

    checkpoints = receive_runtime_checkpoints([])

    started =
      Enum.find(checkpoints, fn checkpoint ->
        get_in(checkpoint, ["combee_policy", "batch_controller", "status"]) ==
          %{"__dsex_type__" => "atom", "value" => "started"} and
          checkpoint["budget_ledger"] != [] and
          get_in(checkpoint, ["pending_proposal_batch", "status"]) == "started"
      end)

    assert started

    assert_raise ArgumentError, ~r/started ComBee profiling trial/, fn ->
      Engine.run(
        %FixtureAdapter{},
        %{main: "base"},
        Enum.to_list(0..3),
        [:validation],
        fn _, _, _, _, _ -> flunk("resume must not dispatch provider work") end,
        max_iterations: 2,
        combee: [
          max_concurrency: 1,
          batch_controller: [
            candidate_batch_sizes: [2, 4],
            max_batch_size: 4,
            profiling_timeout: 25
          ]
        ],
        resume_state: json_round_trip(started)
      )
    end

    tampered = put_in(started, ["combee_policy", "batch_controller", "elapsed_ms"], 99.0)

    assert_raise ArgumentError, ~r/report identity mismatch/, fn ->
      tampered |> json_round_trip() |> Map.fetch!("combee_policy") |> ComBee.load_policy!()
    end
  end

  defp policy(trainset_size, overrides) do
    seed = Keyword.get(overrides, :seed, 1)
    options = Keyword.drop(overrides, [:seed])

    options
    |> ComBee.resolve(trainset_size, trainset_size, seed)
    |> ComBee.resolve_concurrency(8, 1)
  end

  defp recording_proposer(owner) do
    fn _candidate, _component, records, _iteration, metadata ->
      send(owner, {:model_call, metadata.phase, metadata[:group_index]})

      if metadata.phase == :final,
        do: "improved",
        else: "local-#{metadata.group_index}-#{length(records)}"
    end
  end

  defp receive_calls(0, calls), do: Enum.reverse(calls)

  defp receive_calls(count, calls) do
    receive do
      {:call, _, _, _, _, _, _, _} = call -> receive_calls(count - 1, [call | calls])
    after
      1_000 -> flunk("expected #{count} more reducer calls")
    end
  end

  defp receive_model_calls(0, calls), do: Enum.reverse(calls)

  defp receive_model_calls(count, calls) do
    receive do
      {:model_call, _, _} = call -> receive_model_calls(count - 1, [call | calls])
    after
      1_000 -> flunk("expected #{count} more model calls")
    end
  end

  defp receive_deadline_calls(calls) do
    receive do
      {:deadline_call, phase, index} -> receive_deadline_calls([{phase, index} | calls])
    after
      25 -> Enum.reverse(calls)
    end
  end

  defp receive_proposal_deadline_calls(calls) do
    receive do
      {:proposal_deadline_call, component, phase} ->
        receive_proposal_deadline_calls([{component, phase} | calls])
    after
      25 -> Enum.reverse(calls)
    end
  end

  defp receive_runtime_trial_calls(calls) do
    receive do
      {:runtime_trial_call, _, _, _} = call ->
        receive_runtime_trial_calls(calls ++ [call])
    after
      25 -> calls
    end
  end

  defp receive_profile_deadline_calls(calls) do
    receive do
      {:profile_deadline_call, _, _} = call ->
        receive_profile_deadline_calls(calls ++ [call])
    after
      25 -> calls
    end
  end

  defp receive_runtime_checkpoints(checkpoints) do
    receive do
      {:runtime_checkpoint, checkpoint} ->
        receive_runtime_checkpoints(checkpoints ++ [checkpoint])
    after
      25 -> checkpoints
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
