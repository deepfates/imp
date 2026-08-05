defmodule Imp.Optimizer.GEPA.V014ExecutionProfileTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.GEPA
  alias Imp.Optimizer.GEPA.{Adapter, Candidate, Engine, Evaluation, ProgramAdapter, Result}
  alias Imp.Optimizer.Trajectory

  @seeds [2_026_072_602, 2_026_072_603, 2_026_072_604]

  @expected %{
    2_026_072_602 => [
      {0, [5, 12, 31, 21, 0, 32, 35, 9, 4, 13]},
      {0, [33, 25, 16, 14, 27, 15, 3, 37, 11, 2]},
      {1, [24, 6, 10, 20, 26, 22, 39, 28, 18, 29]},
      {0, [38, 8, 1, 30, 34, 17, 19, 36, 7, 23]}
    ],
    2_026_072_603 => [
      {0, [10, 23, 32, 17, 2, 15, 13, 1, 27, 33]},
      {0, [4, 12, 14, 22, 36, 6, 37, 19, 8, 29]},
      {2, [16, 11, 34, 30, 18, 9, 26, 28, 3, 31]},
      {1, [25, 39, 0, 24, 21, 38, 5, 7, 20, 35]}
    ],
    2_026_072_604 => [
      {0, [35, 2, 6, 16, 17, 26, 12, 10, 11, 27]},
      {1, [0, 25, 13, 9, 34, 22, 36, 8, 4, 20]},
      {1, [32, 24, 23, 30, 29, 33, 5, 21, 39, 31]},
      {3, [19, 7, 28, 1, 37, 38, 14, 15, 18, 3]}
    ]
  }

  defmodule ScheduleAdapter do
    @behaviour Adapter
    defstruct [:owner]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      level = candidate.main |> String.to_integer()
      ids = Enum.map(batch, & &1.id)
      capture? = Keyword.get(opts, :capture_traces, false)
      send(adapter.owner, {:profile_evaluation, level, ids, capture?})

      scores =
        Enum.map(batch, fn row ->
          if row.id >= 100, do: validation_score(level, row.id - 100), else: level / 10
        end)

      trajectories =
        if capture? do
          %{
            main:
              Enum.zip_with(batch, scores, fn row, score ->
                %Trajectory{index: row.id, example: row, score: score, trace: []}
              end)
          }
        else
          %{}
        end

      Result.new(batch, scores,
        trajectories: trajectories,
        side_information: %{main: ids},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, &{&1, Enum.map(result.outputs, fn row -> %{"id" => row.id} end)})
    end

    defp validation_score(0, _index), do: 0.4

    defp validation_score(level, index) do
      if div(index, 10) == level - 1, do: 0.6, else: 0.3
    end
  end

  defmodule ErrorLM do
    defstruct [:reason]

    def generate(%__MODULE__{reason: reason}, _messages, _opts), do: {:error, reason}
  end

  defmodule OvershootAdapter do
    @behaviour Adapter
    defstruct [:parent_calls]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      level = String.to_integer(candidate.main)
      capture? = Keyword.get(opts, :capture_traces, false)

      scores =
        cond do
          Enum.all?(batch, &(&1.id >= 100)) ->
            Enum.map(batch, fn _ -> if(level == 0, do: 0.4, else: 0.6) end)

          level == 1 ->
            Enum.map(batch, fn _ -> 1.0 end)

          capture? and Agent.get_and_update(adapter.parent_calls, &{&1, &1 + 1}) < 23 ->
            Enum.map(batch, fn _ -> 1.0 end)

          true ->
            Enum.map(batch, fn _ -> 0.0 end)
        end

      trajectories =
        if capture? do
          %{
            main:
              Enum.zip_with(batch, scores, fn row, score ->
                %Trajectory{index: row.id, example: row, score: score, trace: []}
              end)
          }
        else
          %{}
        end

      Result.new(batch, scores,
        trajectories: trajectories,
        side_information: %{main: Enum.map(batch, & &1.id)},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, &{&1, Enum.map(result.outputs, fn row -> %{"id" => row.id} end)})
    end
  end

  defmodule MergeProfileAdapter do
    @behaviour Adapter
    defstruct []

    @impl true
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

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, components),
      do: Map.new(components, &{&1, []})
  end

  test "pinned profile reproduces the four-iteration CPython parent and minibatch schedule" do
    Enum.each(@seeds, fn seed ->
      state = run_profile(seed)
      evaluations = receive_evaluations(13)
      validation_ids = Enum.to_list(100..139)

      assert [{0, ^validation_ids, false} | iteration_evaluations] = evaluations

      actual =
        iteration_evaluations
        |> Enum.chunk_every(3)
        |> Enum.map(fn [parent, child, validation] ->
          {parent_level, minibatch, true} = parent
          {child_level, ^minibatch, false} = child
          {^child_level, child_validation_ids, false} = validation
          assert child_validation_ids == validation_ids
          {parent_level, minibatch}
        end)

      assert actual == Map.fetch!(@expected, seed)
      assert state.budget.metric_calls == 280
      assert state.budget.max_metric_calls == 330
      assert state.budget.reflection_calls == 4
      assert state.budget.max_reflection_calls == 48

      checkpoint = state |> Engine.dump_state() |> json_round_trip()
      assert checkpoint["rng_state"]["algorithm"] == "python_mt19937"

      resumed = run_profile(seed, max_iterations: 4, resume_state: checkpoint)
      resumed_checkpoint = Engine.dump_state(resumed)
      assert resumed_checkpoint["rng_state"] == checkpoint["rng_state"]
      assert resumed_checkpoint["proposal_policy"] == checkpoint["proposal_policy"]
      assert resumed_checkpoint["budget"] == checkpoint["budget"]
    end)
  end

  test "public profile seals pinned defaults and derives the 280-call engine ceiling" do
    reflection_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{__imp_lm_output__: %{"instruction" => "Answer exactly."}}
        end
      )

    optimizer =
      GEPA.new(fn _example, _prediction -> 1.0 end,
        execution_profile: :gepa_v0_1_4,
        generations: 4,
        minibatch_size: 10,
        reflection_lm: reflection_lm
      )

    assert optimizer.reflection_record_mode == :gepa_v0_1_4
    assert optimizer.skip_perfect_score
    assert optimizer.perfect_score == 1.0
    refute optimizer.cache_evaluation
    assert optimizer.rng_algorithm == :python_v3
    assert optimizer.max_reflection_calls == :infinity

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
    program = Imp.predict("question -> answer", lm: lm)
    trainset = Enum.map(0..39, &example(&1))
    validation = Enum.map(100..139, &example(&1))

    {_compiled, report} = GEPA.compile_with_report(optimizer, program, trainset, validation)
    assert report.metadata.max_metric_calls == 280
    assert report.metadata.operational_metric_call_cap == 330
    assert report.metadata.max_reflection_calls == 48
    assert report.metadata.metric_calls == 280
    assert report.metadata.reflection_calls == 0
    assert report.candidate_count == 1
  end

  test "public merge profile changes only the authenticated merge treatment" do
    reflection_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{__imp_lm_output__: %{"instruction" => "Answer exactly."}}
        end
      )

    no_merge =
      GEPA.new(fn _example, _prediction -> 1.0 end,
        execution_profile: :gepa_v0_1_4,
        max_metric_calls: 80,
        reflection_lm: reflection_lm
      )

    merge =
      GEPA.new(fn _example, _prediction -> 1.0 end,
        execution_profile: :gepa_v0_1_4_merge,
        max_metric_calls: 80,
        reflection_lm: reflection_lm
      )

    refute no_merge.use_merge
    assert merge.use_merge

    for optimizer <- [no_merge, merge] do
      assert optimizer.reflection_record_mode == :gepa_v0_1_4
      assert optimizer.candidate_selection_strategy == :pareto
      assert optimizer.module_selector == :round_robin
      assert optimizer.sampling_strategy == :single
      assert optimizer.selection_strategy == :all_improvements
      assert optimizer.proposal_concurrency == 1
      assert optimizer.max_concurrency == 1
      assert optimizer.frontier_type == :instance
      assert optimizer.acceptance_policy == :strict_improvement
      assert optimizer.merge_acceptance_policy == :equal_or_better
      assert optimizer.rng_algorithm == :python_v3
      refute optimizer.cache_evaluation
    end

    assert_raise ArgumentError, ~r/requires :use_merge: true/, fn ->
      GEPA.new(fn _example, _prediction -> 1.0 end,
        execution_profile: :gepa_v0_1_4_merge,
        use_merge: false,
        max_metric_calls: 80,
        reflection_lm: reflection_lm
      )
    end
  end

  test "merge profile executes the source-shaped scheduled merge path" do
    root = %{planner: "base planner", writer: "base writer"}
    left = %{planner: "left planner", writer: "base writer"}
    right = %{planner: "base planner", writer: "right writer"}
    valset = [:planner, :writer, :tie_one, :tie_two, :tie_three]

    common_opts = [
      execution_profile: :gepa_v0_1_4_merge,
      rng_algorithm: :python_v3,
      reflection_failure_policy: :gepa_v0_1_4_batch_then_single_retry,
      minibatch_size: 1,
      candidate_selection_strategy: :pareto,
      module_selector: :round_robin,
      sampling_strategy: :single,
      selection_strategy: :all_improvements,
      proposal_concurrency: 1,
      acceptance_policy: :strict_improvement,
      use_merge: true,
      cache_evaluation: false,
      skip_perfect_score: true,
      perfect_score: 1.0,
      max_metric_calls: 100,
      max_reflection_calls: 10,
      seed: 5
    ]

    %Engine.State{} =
      initial =
      Engine.run(
        %MergeProfileAdapter{},
        root,
        [:planner],
        valset,
        fn _, _, _, _ -> flunk("zero iterations must not propose") end,
        Keyword.put(common_opts, :max_iterations, 0)
      )

    validation = fn candidate ->
      MergeProfileAdapter.evaluate(%MergeProfileAdapter{}, valset, candidate, [])
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

    merged =
      Engine.run(
        %MergeProfileAdapter{},
        root,
        [:planner],
        valset,
        fn _, _, _, _ -> flunk("scheduled merge must preempt reflection") end,
        common_opts
        |> Keyword.put(:max_iterations, 3)
        |> Keyword.put(:resume_state, Engine.dump_state(state) |> json_round_trip())
      )

    assert merged.total_merges_tested == 1

    assert List.last(merged.candidates).candidate == %{
             planner: "left planner",
             writer: "right writer"
           }

    assert %{operation: :merge, status: :accepted, parent_ids: [1, 2], ancestor: 0} =
             List.last(merged.history)
  end

  test "public pinned profile derives legal execution from a finite semantic metric budget" do
    reflection_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{__imp_lm_output__: %{"instruction" => "Answer exactly."}}
        end
      )

    optimizer =
      GEPA.new(fn _example, _prediction -> 1.0 end,
        execution_profile: :gepa_v0_1_4,
        generations: 6,
        minibatch_size: 8,
        max_metric_calls: 80,
        max_reflection_calls: 12,
        reflection_lm: reflection_lm
      )

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)
    program = Imp.predict("question -> answer", lm: lm)
    trainset = Enum.map(0..15, &example(&1))
    validation = Enum.map(100..131, &example(&1))

    {_compiled, report} = GEPA.compile_with_report(optimizer, program, trainset, validation)

    assert report.metadata.max_metric_calls == 80
    assert report.metadata.operational_metric_call_cap == 120
    assert report.metadata.max_reflection_calls == 12
    assert report.metadata.max_iterations == 6
    assert report.metadata.metric_calls == 80
  end

  test "pinned stopper permits the exact legal current-iteration overshoot" do
    assert GEPA.v014_budget_envelope(40, 10, 280) == %{
             max_metric_calls: 330,
             max_reflection_calls: 48,
             max_iterations: 24
           }

    {:ok, parent_calls} = Agent.start_link(fn -> 0 end)

    state =
      Engine.run(
        %OvershootAdapter{parent_calls: parent_calls},
        %{main: "0"},
        Enum.map(0..39, &%{id: &1}),
        Enum.map(100..139, &%{id: &1}),
        fn _candidate, _component, _records, _iteration -> "1" end,
        execution_profile: :gepa_v0_1_4,
        rng_algorithm: :python_v3,
        reflection_failure_policy: :gepa_v0_1_4_batch_then_single_retry,
        max_iterations: 24,
        minibatch_size: 10,
        candidate_selection_strategy: :pareto,
        module_selector: :round_robin,
        sampling_strategy: :single,
        selection_strategy: :all_improvements,
        proposal_concurrency: 1,
        acceptance_policy: :strict_improvement,
        use_merge: false,
        cache_evaluation: false,
        skip_perfect_score: true,
        perfect_score: 1.0,
        stopper: Imp.Optimizer.GEPA.Stopper.max_metric_calls(280),
        max_metric_calls: 330,
        max_reflection_calls: 48,
        seed: 5
      )

    assert state.budget.metric_calls == 330
    assert state.stop_reason == {:stopper, [{:max_metric_calls, 330, 280}]}
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "1"]
  end

  test "pinned reflection retries one failed singleton and accounts both attempts" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    proposer = fn _candidate, _component, _records, _iteration ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, :batch_reflection_failed}
        1 -> "1"
      end
    end

    state = run_profile(5, max_iterations: 1, max_metric_calls: 100, proposer: proposer)

    assert Agent.get(calls, & &1) == 2
    assert state.budget.reflection_calls == 2
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "1"]
  end

  test "pinned reflection never retries an operational safety failure" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    safety =
      Imp.OperationalSafetyError.exception(
        kind: :route,
        reason: :route_drift,
        message: "optimizer route drift"
      )

    proposer = fn _candidate, _component, _records, _iteration ->
      Agent.update(calls, &(&1 + 1))
      {:error, {:wrapped, safety}}
    end

    assert_raise Imp.OperationalSafetyError, "optimizer route drift", fn ->
      run_profile(5, max_iterations: 1, max_metric_calls: 100, proposer: proposer)
    end

    assert Agent.get(calls, & &1) == 1
  end

  test "pinned records omit feedback when the target predictor did not execute" do
    adapter = %ProgramAdapter{
      program: nil,
      metric: fn _, _ -> 0.0 end,
      reflection_record_mode: :gepa_v0_1_4
    }

    result =
      Result.new([nil], [0.0],
        trajectories: %{main: [nil]},
        side_information: %{main: [{:task_error, "failed before predictor"}]}
      )

    assert ProgramAdapter.make_reflective_dataset(adapter, %{main: "instruction"}, result, [
             :main
           ]) == %{main: []}
  end

  test "operational safety errors remain fatal while ordinary row failures stay score zero" do
    safety =
      Imp.OperationalSafetyError.exception(
        kind: :cost,
        reason: :nonzero_cost,
        message: "provider cost guard drift"
      )

    assert_raise Imp.OperationalSafetyError, "provider cost guard drift", fn ->
      evaluate_error_lm({:wrapped, safety})
    end

    result = evaluate_error_lm({:parse_error, :malformed})
    assert result.scores == [0.0]
    assert result.metadata.failures == 1
  end

  defp run_profile(seed, overrides \\ []) do
    {proposer, overrides} =
      Keyword.pop(overrides, :proposer, fn _candidate, _component, _records, iteration ->
        Integer.to_string(iteration)
      end)

    opts =
      Keyword.merge(
        [
          execution_profile: :gepa_v0_1_4,
          rng_algorithm: :python_v3,
          reflection_failure_policy: :gepa_v0_1_4_batch_then_single_retry,
          max_iterations: 4,
          minibatch_size: 10,
          candidate_selection_strategy: :pareto,
          module_selector: :round_robin,
          sampling_strategy: :single,
          selection_strategy: :all_improvements,
          proposal_concurrency: 1,
          acceptance_policy: :strict_improvement,
          use_merge: false,
          cache_evaluation: false,
          skip_perfect_score: true,
          perfect_score: 1.0,
          max_metric_calls: 330,
          max_reflection_calls: 48,
          seed: seed
        ],
        overrides
      )

    Engine.run(
      %ScheduleAdapter{owner: self()},
      %{main: "0"},
      Enum.map(0..39, &%{id: &1}),
      Enum.map(100..139, &%{id: &1}),
      proposer,
      opts
    )
  end

  defp receive_evaluations(count), do: receive_evaluations(count, [])
  defp receive_evaluations(0, received), do: Enum.reverse(received)

  defp receive_evaluations(count, received) do
    receive do
      {:profile_evaluation, level, ids, capture?} ->
        receive_evaluations(count - 1, [{level, ids, capture?} | received])
    after
      1_000 -> flunk("missing pinned GEPA evaluation event")
    end
  end

  defp example(id),
    do: Imp.example(question: "q#{id}", answer: "ok") |> Imp.with_inputs(:question)

  defp evaluate_error_lm(reason) do
    program = Imp.predict("question -> answer", lm: %ErrorLM{reason: reason})
    adapter = ProgramAdapter.new(program, fn _example, _prediction -> 1.0 end)

    Evaluation.evaluate(adapter, [example(1)], Candidate.from_program(program),
      capture_traces: true
    )
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
