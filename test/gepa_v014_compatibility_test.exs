defmodule Imp.Optimizer.GEPA.V014CompatibilityTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.GEPA.{Adapter, BatchSampler, Engine, ReflectionStrategy, Result}
  alias Imp.Optimizer.GEPA, as: GEPAOptimizer
  alias Imp.Optimizer.Trajectory

  test "public GEPA forwards the released candidate parent selector" do
    optimizer =
      GEPAOptimizer.new(fn _example, _prediction -> 1.0 end,
        candidate_selection_strategy: :current_best,
        generations: 0
      )

    assert optimizer.candidate_selection_strategy == :current_best

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "yes"} end)
      )

    row = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)
    selected = GEPAOptimizer.compile(optimizer, program, [row], [row])

    assert Imp.Optimizer.Report.fetch(selected).metadata.candidate_selection_strategy ==
             :current_best
  end

  defmodule BatchAdapter do
    @behaviour Adapter
    defstruct [:owner, :state]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      if adapter.state,
        do: Agent.update(adapter.state, &Map.update(&1, :evaluations, 1, fn n -> n + 1 end))

      level = candidate.main |> to_string() |> String.to_integer()
      scores = List.duplicate(level * 1.0, length(batch))

      trajectories =
        if Keyword.get(opts, :capture_traces, false) do
          %{
            main:
              Enum.map(
                batch,
                &%Trajectory{index: &1.id, example: &1, score: level * 1.0, trace: []}
              )
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
    def batch_evaluate(adapter, items, opts) do
      send(
        adapter.owner,
        {:batch_evaluate, length(items),
         Enum.map(items, fn {_candidate, batch} -> Enum.map(batch, & &1.id) end)}
      )

      Enum.map(items, fn {candidate, batch} ->
        evaluate(adapter, batch, candidate, Keyword.put(opts, :capture_traces, true))
      end)
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        {component, Enum.map(result.outputs, &%{"id" => &1.id})}
      end)
    end

    @impl true
    def get_adapter_state(%__MODULE__{state: nil}), do: %{}
    def get_adapter_state(%__MODULE__{state: state}), do: Agent.get(state, & &1)

    @impl true
    def set_adapter_state(%__MODULE__{state: nil} = adapter, _state), do: adapter

    def set_adapter_state(%__MODULE__{state: state} = adapter, restored) do
      Agent.update(state, fn _ -> restored end)
      adapter
    end
  end

  defmodule ChainingStrategy do
    @behaviour ReflectionStrategy

    @impl true
    def reflect(_candidate, _dataset, [component], context) do
      proposal = %{
        new_texts: %{component => Integer.to_string(context.generation + 1)},
        prompts: %{component => "prompt-#{context.generation}"},
        raw_lm_outputs: %{component => "raw-#{context.generation}"},
        metadata: %{"prompt:spoof" => "reserved", "generation" => context.generation}
      }

      {proposal,
       %{
         context
         | generation: context.generation + 1,
           total_cost: context.total_cost + 0.6
       }}
    end

    @impl true
    def total_cost(context), do: context.total_cost

    @impl true
    def dump_state(context), do: context

    @impl true
    def load_state(state), do: state
  end

  defmodule SemanticStrategy do
    def reflect(_candidate, _dataset, [component]) do
      {%{new_texts: %{component => "7"}}, __MODULE__}
    end

    def total_cost, do: 0.0
  end

  defmodule MalformedBatchStrategy do
    @behaviour ReflectionStrategy

    @impl true
    def reflect(_candidate, _dataset, [component], context) do
      send(context.owner, :unexpected_reflect_retry)
      {%{new_texts: %{component => "99"}}, context}
    end

    @impl true
    def reflect_many(jobs, context) do
      send(context.owner, {:reflect_many, length(jobs)})

      {[],
       %{context | batch_calls: context.batch_calls + 1, total_cost: context.total_cost + 0.75}}
    end

    @impl true
    def total_cost(context), do: context.total_cost
  end

  defmodule InvalidEntryBatchStrategy do
    @behaviour ReflectionStrategy

    @impl true
    def reflect(_candidate, _dataset, [component], context) do
      send(context.owner, {:individual_reflect, context.mode})

      {%{new_texts: %{component => "8"}},
       %{context | individual_calls: context.individual_calls + 1}}
    end

    @impl true
    def reflect_many(jobs, context) do
      send(context.owner, {:invalid_batch, context.mode, length(jobs)})

      case context.mode do
        :malformed_entries ->
          {List.duplicate(:malformed, length(jobs)),
           %{context | batch_calls: context.batch_calls + 1}}

        :batch_error ->
          {:error, :batch_reflection_failed}
      end
    end

    @impl true
    def total_cost(_context), do: 0.0
  end

  defmodule FailingReflectionStrategy do
    def reflect(_candidate, _dataset, _components),
      do: raise(ArgumentError, "custom reflection failed")

    def total_cost, do: 0.0
  end

  defmodule ExplodingBatchAdapter do
    @behaviour Adapter
    defstruct []

    def evaluate(_adapter, batch, _candidate, opts) do
      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Result.new(batch, List.duplicate(0.0, length(batch)),
        trajectories: trajectories,
        metadata: %{metric_calls: length(batch)}
      )
    end

    def batch_evaluate(adapter, items, opts) do
      if Enum.all?(items, fn {_candidate, batch} -> Enum.all?(batch, &(&1.id >= 10)) end) do
        Enum.map(items, fn {candidate, batch} -> evaluate(adapter, batch, candidate, opts) end)
      else
        raise ArgumentError, "batch explosion"
      end
    end

    def make_reflective_dataset(_adapter, _candidate, _result, _components), do: %{}
  end

  defmodule DrawingSelector do
    @behaviour Imp.Optimizer.GEPA.CandidateSelector
    defstruct [:owner, :tag]

    @impl true
    def select_candidate(%__MODULE__{} = selector, state, rng_state) do
      {draw, rng_state} = :rand.uniform_s(rng_state)
      send(selector.owner, {:selector_draw, selector.tag, draw})
      {hd(state.candidates).id, rng_state}
    end
  end

  defmodule SideEffectThenRaiseAdapter do
    @behaviour Adapter
    defstruct [:owner]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      BatchAdapter.evaluate(%BatchAdapter{owner: adapter.owner}, batch, candidate, opts)
    end

    @impl true
    def batch_evaluate(adapter, items, opts) do
      if Enum.all?(items, fn {_candidate, batch} -> Enum.all?(batch, &(&1.id >= 10)) end) do
        Enum.map(items, fn {candidate, batch} -> evaluate(adapter, batch, candidate, opts) end)
      else
        calls = Enum.sum(Enum.map(items, fn {_candidate, batch} -> length(batch) end))
        send(adapter.owner, {:ambiguous_batch_side_effect, calls})
        raise "batch failed after external metric effects"
      end
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component -> {component, result.outputs} end)
    end
  end

  defmodule BatchContractAdapter do
    @behaviour Adapter
    defstruct [:owner, :fail_candidate]

    @impl true
    def evaluate(adapter, _batch, _candidate, _opts) do
      send(adapter.owner, :direct_evaluate_called)
      raise "engine bypassed adapter batch_evaluate"
    end

    @impl true
    def batch_evaluate(adapter, items, opts) do
      send(
        adapter.owner,
        {:singleton_batch, length(items),
         Enum.map(items, fn {candidate, batch} -> {candidate.main, Enum.map(batch, & &1.id)} end),
         Keyword.fetch!(opts, :capture_traces)}
      )

      Enum.map(items, fn {candidate, batch} ->
        if candidate.main == adapter.fail_candidate and Enum.all?(batch, &(&1.id >= 10)) do
          raise "validation batch failed"
        end

        score = candidate.main |> String.to_integer() |> Kernel.*(1.0)

        Result.new(batch, List.duplicate(score, length(batch)),
          trajectories: %{main: List.duplicate(nil, length(batch))},
          side_information: %{main: Enum.map(batch, & &1.id)},
          metadata: %{metric_calls: length(batch)}
        )
      end)
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        {component, Enum.map(result.outputs, &%{"id" => &1.id})}
      end)
    end
  end

  defmodule StrategyStageFailureAdapter do
    @behaviour Adapter
    defstruct [:stage]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      result = BatchAdapter.evaluate(%BatchAdapter{}, batch, candidate, opts)
      calls = metric_call_reservation(adapter, batch, candidate, opts)
      %{result | metadata: Map.put(result.metadata, :metric_calls, calls)}
    end

    @impl true
    def batch_evaluate(%__MODULE__{stage: :validation} = adapter, items, opts) do
      if Enum.any?(items, fn {candidate, batch} ->
           candidate.main != "0" and Enum.all?(batch, &(&1.id >= 10))
         end) do
        raise ArgumentError, "strategy validation exploded"
      end

      Enum.map(items, fn {candidate, batch} -> evaluate(adapter, batch, candidate, opts) end)
    end

    def batch_evaluate(adapter, items, opts) do
      Enum.map(items, fn {candidate, batch} -> evaluate(adapter, batch, candidate, opts) end)
    end

    @impl true
    def make_reflective_dataset(
          %__MODULE__{stage: :reflective_dataset},
          _candidate,
          _result,
          _components
        ) do
      raise ArgumentError, "reflective dataset exploded"
    end

    def make_reflective_dataset(_adapter, candidate, result, components) do
      BatchAdapter.make_reflective_dataset(%BatchAdapter{}, candidate, result, components)
    end

    @impl true
    def metric_call_reservation(_adapter, batch, %{main: "0"}, _opts) do
      if Enum.all?(batch, &(&1.id >= 10)), do: 0, else: length(batch)
    end

    def metric_call_reservation(_adapter, batch, _candidate, _opts), do: length(batch)
  end

  test "same-parent proposals are accepted once, selected by margin, and full-evaluated together" do
    {:ok, acceptance_calls} = Agent.start_link(fn -> 0 end)

    acceptance =
      {:callback,
       fn context ->
         Agent.update(acceptance_calls, &(&1 + 1))
         context.after_score > context.before_score
       end}

    state =
      run(
        sampling_strategy: {:same_parent, 3},
        selection_strategy: {:top_k, 2},
        acceptance_policy: acceptance
      )

    assert Agent.get(acceptance_calls, & &1) == 3
    assert Enum.map(state.candidates, & &1.discovered_at) == [0, 8, 10]
    assert length(state.candidates) == 3

    assert [%{reason: {:not_selected, {:top_k, 2}}}] = state.rejected

    assert_receive {:batch_evaluate, 3, parent_batches}
    assert parent_batches |> List.flatten() |> Enum.uniq() |> length() == 3
    assert_receive {:batch_evaluate, 3, _child_batches}
    assert_receive {:batch_evaluate, 2, [[10, 11], [10, 11]]}
  end

  test "proposal concurrency caps strategy task sampling and adapter batch width" do
    _state =
      run(
        sampling_strategy: {:pxn, 2, 2},
        proposal_concurrency: 2,
        max_iterations: 1
      )

    assert_receive {:batch_evaluate, 2, _parent_batches}
    assert_receive {:batch_evaluate, 2, _child_batches}
    refute_receive {:batch_evaluate, 3, _}
    refute_receive {:batch_evaluate, 4, _}
  end

  test "identical selected children produce one candidate and a duplicate rejection" do
    state =
      run(
        sampling_strategy: {:same_parent, 2},
        selection_strategy: :all_improvements,
        proposer: fn _candidate, _component, _records, _iteration -> "9" end
      )

    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "9"]

    assert Enum.any?(
             state.rejected,
             &match?({:duplicate_candidate, :selected_this_iteration}, &1.reason)
           )

    assert_receive {:batch_evaluate, 2, _parents}
    assert_receive {:batch_evaluate, 2, _children}
    assert_receive {:batch_evaluate, 1, [[10, 11]]}
  end

  test "duplicate callback selections remain explicit rejection events" do
    selection =
      {:callback,
       fn proposals, _state, accepted? ->
         proposal = Enum.find(proposals, accepted?)
         [proposal, proposal]
       end}

    state = run(selection_strategy: selection)

    assert ["0", accepted] = Enum.map(state.candidates, & &1.candidate.main)
    refute accepted == "0"

    assert Enum.count(
             state.rejected,
             &match?({:duplicate_proposal_selection, _slot}, &1.reason)
           ) == 1
  end

  test "independent and pxn sampling interleave parent RNG draws with minibatch sampling" do
    schedules = [
      {{:independent, 3}, [1, 1, 1]},
      {{:pxn, 2, 2}, [2, 2]}
    ]

    Enum.each(schedules, fn {strategy, groups} ->
      tag = make_ref()

      state =
        run(
          sampling_strategy: strategy,
          candidate_selection_strategy: %DrawingSelector{owner: self(), tag: tag}
        )

      {expected_draws, expected_shuffle, expected_rng} =
        reference_sampling_schedule(5, 6, groups)

      actual_draws =
        Enum.map(groups, fn _group ->
          assert_receive {:selector_draw, ^tag, draw}
          draw
        end)

      assert actual_draws == expected_draws
      assert state.batch_sampler.shuffled_ids == expected_shuffle
      assert state.rng_state == expected_rng
    end)
  end

  test "adapter state is snapshotted, restored, and absent schema-4 state migrates" do
    {:ok, first_store} = Agent.start_link(fn -> %{evaluations: 0, session: "first"} end)

    first =
      run(
        adapter: %BatchAdapter{owner: self(), state: first_store},
        max_iterations: 0
      )

    assert first.adapter_state == %{evaluations: 1, session: "first"}
    checkpoint = Engine.dump_state(first)
    assert checkpoint["schema_version"] == 7

    {:ok, resumed_store} = Agent.start_link(fn -> %{evaluations: 0} end)

    resumed =
      run(
        adapter: %BatchAdapter{owner: self(), state: resumed_store},
        max_iterations: 0,
        resume_state: checkpoint
      )

    assert Agent.get(resumed_store, & &1) == %{evaluations: 1, session: "first"}
    assert resumed.adapter_state == %{evaluations: 1, session: "first"}

    schema4 =
      checkpoint
      |> Map.put("schema_version", 4)
      |> Map.delete("adapter_state")
      |> Map.delete("batch_sampler")
      |> Map.delete("reflection_strategy_state")

    migrated = run(max_iterations: 0, resume_state: schema4)
    assert migrated.adapter_state == %{}
  end

  test "sampler size is checkpoint identity and schema 6 migration binds stored effective size" do
    sampling_strategy = {:same_parent, 1}

    partial =
      run(max_iterations: 1, minibatch_size: 2, sampling_strategy: sampling_strategy)

    checkpoint = partial |> Engine.dump_state() |> json_round_trip()

    assert checkpoint["schema_version"] == 7
    assert checkpoint["batch_sampler"]["minibatch_size"] == 2

    resumed =
      run(
        max_iterations: 2,
        minibatch_size: 2,
        sampling_strategy: sampling_strategy,
        resume_state: checkpoint
      )

    uninterrupted =
      run(max_iterations: 2, minibatch_size: 2, sampling_strategy: sampling_strategy)

    assert Engine.dump_state(resumed) == Engine.dump_state(uninterrupted)

    assert_raise ArgumentError, ~r/resume minibatch size mismatch/, fn ->
      run(
        max_iterations: 2,
        minibatch_size: 1,
        sampling_strategy: sampling_strategy,
        resume_state: checkpoint
      )
    end

    schema6 =
      checkpoint
      |> Map.put("schema_version", 6)
      |> update_in(["batch_sampler"], &Map.delete(&1, "minibatch_size"))

    migrated =
      run(
        max_iterations: 1,
        minibatch_size: 2,
        sampling_strategy: sampling_strategy,
        resume_state: schema6
      )

    assert migrated.batch_sampler.minibatch_size == 2

    assert_raise ArgumentError, ~r/resume minibatch size mismatch/, fn ->
      run(
        max_iterations: 2,
        minibatch_size: 1,
        sampling_strategy: sampling_strategy,
        resume_state: schema6
      )
    end
  end

  test "contextual reflection strategy chains successors and stops on observable cost" do
    strategy =
      ReflectionStrategy.contextual(ChainingStrategy, %{generation: 0, total_cost: 0.0})

    state =
      run(
        max_iterations: 2,
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy,
        max_reflection_cost: 1.0
      )

    assert state.reflection_strategy.context.generation == 2
    assert state.reflection_strategy.context.total_cost == 1.2
    assert state.stop_reason == {:max_reflection_cost, 1.2, 1.0}
    assert state.iteration == 1
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "1", "2"]
  end

  test "malformed reflect_many count falls back to per-job reflection" do
    strategy =
      ReflectionStrategy.contextual(MalformedBatchStrategy, %{
        owner: self(),
        batch_calls: 0,
        total_cost: 0.0
      })

    state =
      run(
        max_iterations: 2,
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy,
        max_reflection_cost: 0.5
      )

    assert_receive {:reflect_many, 2}
    assert_receive :unexpected_reflect_retry
    assert_receive :unexpected_reflect_retry
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "99"]
    assert state.reflection_strategy.context.batch_calls == 1
    assert state.reflection_strategy.context.total_cost == 0.75
  end

  test "same-length malformed batch entries retry every reflection individually" do
    strategy =
      ReflectionStrategy.contextual(InvalidEntryBatchStrategy, %{
        owner: self(),
        mode: :malformed_entries,
        batch_calls: 0,
        individual_calls: 0
      })

    state =
      run(
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy,
        max_iterations: 1
      )

    assert_receive {:invalid_batch, :malformed_entries, 2}
    assert_receive {:individual_reflect, :malformed_entries}
    assert_receive {:individual_reflect, :malformed_entries}
    assert state.reflection_strategy.context.batch_calls == 1
    assert state.reflection_strategy.context.individual_calls == 2
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "8"]
  end

  test "batch reflection errors retry every reflection individually" do
    strategy =
      ReflectionStrategy.contextual(InvalidEntryBatchStrategy, %{
        owner: self(),
        mode: :batch_error,
        batch_calls: 0,
        individual_calls: 0
      })

    state =
      run(
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy,
        max_iterations: 1
      )

    assert_receive {:invalid_batch, :batch_error, 2}
    assert_receive {:individual_reflect, :batch_error}
    assert_receive {:individual_reflect, :batch_error}
    assert state.reflection_strategy.context.individual_calls == 2
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "8"]
  end

  test "strategy proposer and custom reflection exceptions obey raise_on_exception" do
    proposer = fn _candidate, _component, _records, _iteration ->
      raise ArgumentError, "strategy proposer failed"
    end

    assert_raise ArgumentError, "strategy proposer failed", fn ->
      run(
        proposer: proposer,
        sampling_strategy: {:same_parent, 2},
        raise_on_exception: true
      )
    end

    rejected =
      run(
        proposer: proposer,
        sampling_strategy: {:same_parent, 2},
        raise_on_exception: false
      )

    assert rejected.budget.reflection_calls == 2
    assert length(rejected.rejected) == 2

    assert_raise ArgumentError, "custom reflection failed", fn ->
      run(reflection_strategy: FailingReflectionStrategy, raise_on_exception: true)
    end

    reflected =
      run(reflection_strategy: FailingReflectionStrategy, raise_on_exception: false)

    assert reflected.budget.reflection_calls == 1

    assert [%{reason: {:proposal_error, {:reflection_strategy_exception, _message}}}] =
             reflected.rejected
  end

  test "stateful reflection and sampler state resume exactly from a JSON checkpoint" do
    strategy = fn ->
      ReflectionStrategy.contextual(ChainingStrategy, %{generation: 0, total_cost: 0.0})
    end

    partial =
      run(
        max_iterations: 1,
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy.()
      )

    checkpoint = partial |> Engine.dump_state() |> json_round_trip()

    resumed =
      run(
        max_iterations: 2,
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy.(),
        resume_state: checkpoint
      )

    uninterrupted =
      run(
        max_iterations: 2,
        sampling_strategy: {:same_parent, 2},
        reflection_strategy: strategy.()
      )

    assert Engine.dump_state(resumed) == Engine.dump_state(uninterrupted)
    assert resumed.reflection_strategy.context == %{generation: 4, total_cost: 2.4}
  end

  test "checkpointing a contextual strategy without codecs is rejected explicitly" do
    strategy =
      ReflectionStrategy.contextual(MalformedBatchStrategy, %{
        owner: self(),
        batch_calls: 0,
        total_cost: 0.0
      })

    state = run(max_iterations: 0, reflection_strategy: strategy)

    assert_raise ArgumentError, ~r/is not checkpointable/, fn ->
      Engine.dump_state(state)
    end
  end

  test "captured function strategies checkpoint only before their first reflection" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    strategy = fn _candidate, _dataset, [component] ->
      Agent.update(calls, &(&1 + 1))
      %{new_texts: %{component => "8"}}
    end

    unstarted = run(max_iterations: 0, reflection_strategy: strategy)
    checkpoint = unstarted |> Engine.dump_state() |> json_round_trip()

    assert checkpoint["reflection_strategy_state"] == %{
             "kind" => "function_pre_reflection"
           }

    resumed = run(max_iterations: 0, reflection_strategy: strategy, resume_state: checkpoint)
    assert resumed.budget.reflection_calls == 0
    assert Agent.get(calls, & &1) == 0

    started = run(max_iterations: 1, reflection_strategy: strategy)
    assert started.budget.reflection_calls == 1
    assert Agent.get(calls, & &1) == 1

    assert_raise ArgumentError, ~r/not checkpointable after reflection calls/, fn ->
      Engine.dump_state(started)
    end
  end

  test "single sampler keeps one shuffle through offsets and wraps before the next epoch" do
    trainset = Enum.to_list(0..4)
    rng0 = :rand.seed_s(:exsss, {6, 7, 8})

    {iteration_zero, sampler0, rng1} =
      BatchSampler.next_batches(BatchSampler.new(), trainset, 2, 4, 0, rng0)

    ids0 = Enum.map(iteration_zero, &elem(&1, 1))
    assert Enum.concat(Enum.take(ids0, 3)) == sampler0.shuffled_ids
    assert Enum.at(ids0, 3) == Enum.at(ids0, 0)
    assert sampler0.epoch == 0

    {[{_batch, iteration_one}], sampler1, rng2} =
      BatchSampler.next_batches(sampler0, trainset, 2, 1, 1, rng1)

    assert iteration_one == Enum.slice(sampler0.shuffled_ids, 2, 2)
    assert rng2 == rng1

    {[{_batch, iteration_two}], sampler2, rng3} =
      BatchSampler.next_batches(sampler1, trainset, 2, 1, 2, rng2)

    assert iteration_two == Enum.slice(sampler0.shuffled_ids, 4, 2)
    assert rng3 == rng2

    {[{_batch, iteration_three}], sampler3, rng4} =
      BatchSampler.next_batches(sampler2, trainset, 2, 1, 3, rng3)

    assert sampler3.epoch == 1
    refute rng4 == rng3

    {[_baseline_zero], baseline0, baseline_rng1} =
      BatchSampler.next_batches(BatchSampler.new(), trainset, 2, 1, 0, rng0)

    {[_baseline_one], baseline1, baseline_rng2} =
      BatchSampler.next_batches(baseline0, trainset, 2, 1, 1, baseline_rng1)

    {[_baseline_two], baseline2, baseline_rng3} =
      BatchSampler.next_batches(baseline1, trainset, 2, 1, 2, baseline_rng2)

    {[{_batch, baseline_three}], baseline3, baseline_rng4} =
      BatchSampler.next_batches(baseline2, trainset, 2, 1, 3, baseline_rng3)

    assert iteration_three == baseline_three
    assert sampler3.shuffled_ids == baseline3.shuffled_ids
    assert rng4 == baseline_rng4
  end

  test "schema 6 sampler migration accepts its provisional trainset identity" do
    sampler =
      BatchSampler.new()
      |> BatchSampler.bind!(2, [1, 2, 3])
      |> BatchSampler.dump()
      |> Map.delete("minibatch_size")

    migrated = BatchSampler.load_legacy!(sampler, 2)
    assert migrated.minibatch_size == 2
    assert migrated.trainset_identity == nil
  end

  test "systemic evaluation errors obey raise_on_exception" do
    assert_raise ArgumentError, "batch explosion", fn ->
      run(adapter: %ExplodingBatchAdapter{}, raise_on_exception: true)
    end

    state = run(adapter: %ExplodingBatchAdapter{}, raise_on_exception: false)
    assert state.iteration == 1
    assert length(state.candidates) == 1
    assert state.stop_reason == :max_iterations

    assert_raise ArgumentError, "batch explosion", fn ->
      run(
        adapter: %ExplodingBatchAdapter{},
        proposal_concurrency: 1,
        sampling_strategy: :single,
        raise_on_exception: true
      )
    end

    state =
      run(
        adapter: %ExplodingBatchAdapter{},
        proposal_concurrency: 1,
        sampling_strategy: :single,
        raise_on_exception: false
      )

    assert state.iteration == 1
    assert state.stop_reason == :max_iterations
  end

  test "sequential proposal and validation evaluations use singleton adapter batches once" do
    state =
      Engine.run(
        %BatchContractAdapter{owner: self()},
        %{main: "0"},
        Enum.map(1..2, &%{id: &1}),
        [%{id: 10}, %{id: 11}],
        fn _candidate, _component, _records, _iteration -> "1" end,
        max_iterations: 1,
        minibatch_size: 1,
        proposal_concurrency: 1,
        candidate_selection_strategy: :current_best,
        max_metric_calls: 20,
        seed: 5
      )

    assert_receive {:singleton_batch, 1, [{"0", [10, 11]}], false}
    assert_receive {:singleton_batch, 1, [{"0", [_train_id]}], true}
    assert_receive {:singleton_batch, 1, [{"1", [_train_id]}], false}
    assert_receive {:singleton_batch, 1, [{"1", [10, 11]}], false}
    refute_receive :direct_evaluate_called
    assert state.budget.metric_calls == 6
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "1"]
  end

  test "failed sequential validation re-raises or records a charged rejection" do
    run = fn raise_on_exception ->
      Engine.run(
        %BatchContractAdapter{owner: self(), fail_candidate: "1"},
        %{main: "0"},
        [%{id: 1}],
        [%{id: 10}],
        fn _candidate, _component, _records, _iteration -> "1" end,
        max_iterations: 1,
        minibatch_size: 1,
        proposal_concurrency: 1,
        candidate_selection_strategy: :current_best,
        max_metric_calls: 20,
        raise_on_exception: raise_on_exception,
        seed: 5
      )
    end

    assert_raise RuntimeError, "validation batch failed", fn -> run.(true) end

    state = run.(false)
    assert state.budget.metric_calls == 4
    assert length(state.candidates) == 1

    assert [%{reason: {:proposal_error, {:validation_error, {:evaluation_exception, _}}}}] =
             state.rejected
  end

  test "strategy validation batch exceptions append one charged stage rejection per plan" do
    assert_raise ArgumentError, "strategy validation exploded", fn ->
      run_strategy_stage_failure(:validation, true)
    end

    state = run_strategy_stage_failure(:validation, false)

    assert state.budget.metric_calls == 3
    assert state.budget.reflection_calls == 1
    assert length(state.candidates) == 1

    assert [rejection] = state.rejected
    assert rejection.target_candidate_id == 1
    assert rejection.candidate == %{main: "1"}
    assert rejection.stage == :validation
    assert rejection.parent_ids == [0]
    assert rejection.components == [:main]
    assert rejection.validation_instances == [0]
    assert rejection.metric_calls_charged == 1
    assert rejection.reflection_calls_charged == 0

    assert rejection.reason ==
             {:strategy_stage_error, :validation,
              {:exception, ArgumentError, "strategy validation exploded"}}

    assert List.last(state.history) == rejection
  end

  test "reflective dataset exceptions append an attributable zero-charge rejection" do
    assert_raise ArgumentError, "reflective dataset exploded", fn ->
      run_strategy_stage_failure(:reflective_dataset, true)
    end

    state = run_strategy_stage_failure(:reflective_dataset, false)

    assert state.budget.metric_calls == 1
    assert state.budget.reflection_calls == 0
    assert length(state.candidates) == 1

    assert [rejection] = state.rejected
    assert rejection.stage == :reflective_dataset
    assert rejection.source_candidate_id == 0
    assert rejection.candidate == %{main: "0"}
    assert rejection.parent_ids == [0]
    assert rejection.components == [:main]
    assert rejection.minibatch_ids == [0]
    assert rejection.metric_calls_charged == 0
    assert rejection.reflection_calls_charged == 0

    assert rejection.reason ==
             {:strategy_stage_error, :reflective_dataset,
              {:exception, ArgumentError, "reflective dataset exploded"}}

    assert List.last(state.history) == rejection
  end

  test "ambiguous batch evaluation consumes its full authorized metric reservation" do
    state =
      run(
        adapter: %SideEffectThenRaiseAdapter{owner: self()},
        max_iterations: 2,
        max_metric_calls: 3,
        raise_on_exception: false
      )

    assert_receive {:ambiguous_batch_side_effect, 1}
    refute_receive {:ambiguous_batch_side_effect, _calls}
    assert state.budget.metric_calls == 3
    assert state.budget.metric_calls <= state.budget.max_metric_calls
    assert state.stop_reason == {:budget_exhausted, :metric_calls, 4, 3}
  end

  test "public optimizer accepts the v0.1.4 strategy and stopping parameters by name" do
    optimizer =
      GEPAOptimizer.new(fn _example, _prediction -> 1.0 end,
        sampling_strategy: {:pxn, 2, 3},
        selection_strategy: :best_improvement,
        reflection_strategy: SemanticStrategy,
        max_reflection_cost: 2.5,
        raise_on_exception: false
      )

    assert optimizer.sampling_strategy == {:pxn, 2, 3}
    assert optimizer.selection_strategy == :best_improvement
    assert optimizer.reflection_strategy == SemanticStrategy
    assert optimizer.max_reflection_cost == 2.5
    refute optimizer.raise_on_exception

    contextual =
      GEPAOptimizer.new(fn _example, _prediction -> 1.0 end,
        reflection_strategy: {:contextual, ChainingStrategy, %{generation: 0, total_cost: 0.0}},
        max_reflection_cost: 2.5
      )

    assert %ReflectionStrategy{module: ChainingStrategy} = contextual.reflection_strategy
    assert contextual.reflection_strategy.context == %{generation: 0, total_cost: 0.0}

    state = run(reflection_strategy: SemanticStrategy)
    assert Enum.map(state.candidates, & &1.candidate.main) == ["0", "7"]
  end

  test "configured reflection cost cap rejects an unobservable semantic strategy" do
    strategy = fn _candidate, _dataset, _components -> %{new_texts: %{}} end

    assert_raise ArgumentError, ~r/observable total_cost/, fn ->
      GEPAOptimizer.new(fn _example, _prediction -> 1.0 end,
        reflection_strategy: strategy,
        max_reflection_cost: 1.0
      )
    end

    assert_raise ArgumentError, ~r/observable total_cost/, fn ->
      run(reflection_strategy: strategy, max_reflection_cost: 1.0)
    end
  end

  defp run(overrides) do
    {adapter, overrides} = Keyword.pop(overrides, :adapter, %BatchAdapter{owner: self()})

    {proposer, overrides} =
      Keyword.pop(overrides, :proposer, fn _candidate, _component, records, _iteration ->
        records |> hd() |> Map.fetch!("id") |> Kernel.+(1) |> Integer.to_string()
      end)

    opts =
      Keyword.merge(
        [
          max_iterations: 1,
          minibatch_size: 1,
          proposal_concurrency: 4,
          sampling_strategy: :single,
          selection_strategy: :all_improvements,
          candidate_selection_strategy: :current_best,
          max_metric_calls: 100,
          seed: 5
        ],
        overrides
      )

    Engine.run(
      adapter,
      %{main: "0"},
      Enum.map(1..6, &%{id: &1}),
      [%{id: 10}, %{id: 11}],
      proposer,
      opts
    )
  end

  defp run_strategy_stage_failure(stage, raise_on_exception) do
    Engine.run(
      %StrategyStageFailureAdapter{stage: stage},
      %{main: "0"},
      [%{id: 1}],
      [%{id: 10}],
      fn _candidate, _component, _records, _iteration -> "1" end,
      max_iterations: 1,
      minibatch_size: 1,
      proposal_concurrency: 2,
      sampling_strategy: {:same_parent, 1},
      selection_strategy: :all_improvements,
      candidate_selection_strategy: :current_best,
      max_metric_calls: 20,
      raise_on_exception: raise_on_exception,
      seed: 5
    )
  end

  defp reference_sampling_schedule(seed, trainset_size, groups) do
    rng_state = :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3})

    Enum.reduce(groups, {[], nil, rng_state}, fn _mutations, {draws, shuffled_ids, rng_state} ->
      {draw, rng_state} = :rand.uniform_s(rng_state)

      {shuffled_ids, rng_state} =
        if is_nil(shuffled_ids) do
          reference_shuffle(trainset_size, rng_state)
        else
          {shuffled_ids, rng_state}
        end

      {draws ++ [draw], shuffled_ids, rng_state}
    end)
  end

  defp reference_shuffle(size, rng_state) do
    0..(size - 1)
    |> Enum.map_reduce(rng_state, fn id, rng_state ->
      {key, rng_state} = :rand.uniform_s(rng_state)
      {{key, id}, rng_state}
    end)
    |> then(fn {decorated, rng_state} ->
      {decorated |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng_state}
    end)
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
