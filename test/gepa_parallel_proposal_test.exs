defmodule Imp.Optimizer.GEPA.ParallelProposalTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.GEPA.{Adapter, Coordinator, Engine, Result}

  defmodule FixtureAdapter do
    @behaviour Adapter
    defstruct [:owner, delays: %{}]

    @impl true
    def evaluate(adapter, batch, candidate, opts) do
      capture? = Keyword.get(opts, :capture_traces, false)
      iteration = candidate_iteration(candidate)
      phase = if(capture? and iteration > 0, do: :child, else: :parent)
      delay = Map.get(adapter.delays, {phase, batch_id(batch)}, 0)

      if capture?, do: send(adapter.owner, {:evaluation_started, phase, batch_id(batch), self()})
      if delay == :infinity, do: Process.sleep(:infinity), else: Process.sleep(delay)
      if capture?, do: send(adapter.owner, {:evaluation_finished, phase, batch_id(batch), self()})

      scores = List.duplicate(iteration * 1.0, length(batch))

      trajectories =
        if capture?, do: %{main: List.duplicate(nil, length(batch))}, else: %{}

      Result.new(batch, scores,
        trajectories: trajectories,
        side_information: %{main: Enum.map(batch, &inspect/1)},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, &{&1, Enum.map(result.outputs, fn output -> %{output: output} end)})
    end

    defp candidate_iteration(%{main: "base"}), do: 0

    defp candidate_iteration(%{main: instruction}) do
      instruction |> String.replace_prefix("proposal-", "") |> String.to_integer()
    end

    defp batch_id([{:train, id} | _]), do: id
    defp batch_id(_batch), do: :validation
  end

  defmodule RecordingCallback do
    @behaviour Imp.Optimizer.GEPA.Callback

    @impl true
    def on_iteration_start(event, owner),
      do: send(owner, {:callback, :iteration_start, event.iteration})

    @impl true
    def on_candidate_accepted(event, owner) do
      send(owner, {:callback, :accepted, event.iteration, event.new_candidate_idx})
    end

    @impl true
    def on_error(event, owner), do: send(owner, {:callback, :error, event.iteration})
  end

  test "out-of-order workers apply archive IDs and callbacks by proposal slot" do
    state =
      run_engine(
        delays: %{{:parent, 0} => 50, {:parent, 1} => 5, {:child, 0} => 40, {:child, 1} => 1},
        callbacks: [{RecordingCallback, self()}]
      )

    assert Enum.map(state.candidates, & &1.id) == [0, 1, 2]
    assert Enum.map(tl(state.candidates), & &1.candidate.main) == ["proposal-1", "proposal-2"]

    assert callback_messages() == [
             {:callback, :iteration_start, 1},
             {:callback, :accepted, 1, 1},
             {:callback, :iteration_start, 2},
             {:callback, :accepted, 2, 2}
           ]
  end

  test "proposal concurrency is bounded and actually overlaps work" do
    state = run_engine(delays: %{{:parent, 0} => 40, {:parent, 1} => 40})
    assert state.iteration == 2

    starts = receive_evaluation_starts(2, [])
    assert starts |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> length() == 2
  end

  test "metric and reflection reservations stop exactly at boundaries" do
    metric_limited = run_engine(max_metric_calls: 4)
    assert metric_limited.budget.metric_calls == 4
    assert {:budget_exhausted, :metric_calls, 5, 4} = metric_limited.stop_reason

    reflection_limited = run_engine(max_reflection_calls: 1, max_metric_calls: 20)
    assert reflection_limited.budget.reflection_calls == 1
    assert {:budget_exhausted, :reflection_calls, 2, 1} = reflection_limited.stop_reason
  end

  test "worker timeout and proposer crash are isolated by slot" do
    timed_out =
      run_engine(
        delays: %{{:parent, 0} => :infinity},
        proposal_timeout: 15,
        raise_on_exception: false,
        callbacks: [{RecordingCallback, self()}]
      )

    assert timed_out.budget.metric_calls <= timed_out.budget.max_metric_calls
    assert Enum.any?(timed_out.rejected, &match?({:proposal_error, :timeout}, &1.reason))

    crashed =
      run_engine(
        proposer: fn _candidate, _component, _records, iteration ->
          if iteration == 1, do: raise("reflection failed"), else: "proposal-#{iteration}"
        end,
        raise_on_exception: false
      )

    assert length(crashed.candidates) == 2
    assert Enum.any?(crashed.rejected, &(&1.iteration == 1))
  end

  test "speculative proposer exceptions re-raise when configured" do
    assert_raise ArgumentError, "speculative reflection failed", fn ->
      run_engine(
        max_iterations: 1,
        proposer: fn _candidate, _component, _records, _iteration ->
          raise ArgumentError, "speculative reflection failed"
        end,
        raise_on_exception: true
      )
    end
  end

  test "sequential proposer exceptions re-raise or become charged rejections" do
    proposer = fn _candidate, _component, _records, _iteration ->
      raise ArgumentError, "sequential reflection failed"
    end

    assert_raise ArgumentError, "sequential reflection failed", fn ->
      run_engine(
        max_iterations: 1,
        proposal_concurrency: 1,
        proposer: proposer,
        raise_on_exception: true
      )
    end

    state =
      run_engine(
        max_iterations: 1,
        proposal_concurrency: 1,
        proposer: proposer,
        raise_on_exception: false
      )

    assert state.budget.reflection_calls == 1
    assert length(state.candidates) == 1

    assert [%{reason: {:proposal_error, {:proposal_exception, "sequential reflection failed"}}}] =
             state.rejected
  end

  test "caller cancellation terminates proposal workers without admission leases" do
    baseline = MapSet.new(Task.Supervisor.children(Imp.UnlinkedTaskSupervisor))
    owner = self()

    caller =
      spawn(fn ->
        send(owner, :caller_started)
        run_engine(owner: owner, delays: %{{:parent, 0} => :infinity, {:parent, 1} => :infinity})
      end)

    assert_receive :caller_started
    assert_receive {:evaluation_started, :parent, id, worker} when id != :validation, 1_000
    Process.exit(caller, :kill)

    assert eventually(fn ->
             not Process.alive?(worker) and
               MapSet.new(Task.Supervisor.children(Imp.UnlinkedTaskSupervisor)) == baseline and
               Imp.Tasks.admission_status() == %{active: 0, queued: 0}
           end)
  end

  test "untrappable worker death is returned without killing the coordinator" do
    owner = self()

    task =
      Task.async(fn ->
        Coordinator.run([:work], 1_000, fn :work ->
          send(owner, {:coordinator_worker, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:coordinator_worker, worker}
    Process.exit(worker, :kill)

    assert Task.await(task) == [{:error, {:worker_exit, :killed}}]
  end

  test "schema 8 replays prepared work, rejects ambiguous work, tampering, and config mismatch" do
    prepared = interrupt_checkpoint!(:prepared)
    assert prepared["schema_version"] == 8
    assert prepared["pending_proposal_batch"]["status"] == "prepared"

    resumed = run_engine(resume_state: json_round_trip(prepared))
    assert resumed.iteration == 2

    schema4 =
      prepared
      |> Map.put("schema_version", 4)
      |> Map.delete("adapter_state")
      |> Map.delete("batch_sampler")
      |> Map.delete("reflection_strategy_state")
      |> Map.delete("cache_identity")

    strategy_resumed =
      run_engine(
        resume_state: json_round_trip(schema4),
        sampling_strategy: :single,
        selection_strategy: :all_improvements
      )

    assert strategy_resumed.iteration == 2
    assert is_nil(strategy_resumed.pending_proposal_batch)

    child_prepared = interrupt_checkpoint!(:prepared, :child)
    child_resumed = run_engine(resume_state: json_round_trip(child_prepared))
    assert child_resumed.iteration == 2
    assert child_resumed.budget.metric_calls <= child_resumed.budget.max_metric_calls

    started = interrupt_checkpoint!(:started)

    assert_raise ArgumentError, ~r/ambiguous external effects/, fn ->
      run_engine(resume_state: json_round_trip(started))
    end

    tampered =
      put_in(prepared, ["pending_proposal_batch", "contexts", Access.at(0), "parent_id"], 99)

    assert_raise ArgumentError, ~r/integrity mismatch/, fn ->
      run_engine(resume_state: json_round_trip(tampered))
    end

    ledger_tampered =
      update_in(prepared, ["budget_ledger", Access.at(0), "metric_calls"], &(&1 + 1))

    assert_raise ArgumentError, ~r/checkpoint integrity mismatch/, fn ->
      run_engine(resume_state: json_round_trip(ledger_tampered))
    end

    complete = run_engine() |> Engine.dump_state() |> json_round_trip()

    assert_raise ArgumentError, ~r/proposal policy mismatch/, fn ->
      run_engine(resume_state: complete, proposal_concurrency: 1)
    end
  end

  test "default and explicit concurrency one retain identical deterministic state" do
    implicit = run_engine(proposal_concurrency: 1)
    explicit = run_engine(proposal_concurrency: 1)
    assert Engine.dump_state(implicit) == Engine.dump_state(explicit)
  end

  test "public validation accepts auto and rejects pre-canonical checkpoints" do
    metric = fn _example, _prediction -> 1.0 end

    assert %Imp.Optimizer.GEPA{proposal_concurrency: :auto} =
             Imp.Optimizer.GEPA.new(metric, proposal_concurrency: :auto)

    assert_raise ArgumentError, ~r/invalid value for :proposal_concurrency option/, fn ->
      Imp.Optimizer.GEPA.new(metric, proposal_concurrency: 0)
    end

    legacy =
      run_engine()
      |> Engine.dump_state()
      |> Map.put("schema_version", 1)
      |> Map.delete("budget_ledger")
      |> Map.delete("pending_proposal_batch")
      |> Map.delete("pending_proposal_integrity")
      |> Map.delete("proposal_policy")
      |> Map.delete("combee_policy")
      |> Map.delete("combee_reports")
      |> update_in(["budget"], &Map.delete(&1, "max_reflection_calls"))
      |> json_round_trip()

    assert_raise ArgumentError, ~r/invalid GEPA engine resume state/, fn ->
      run_engine(resume_state: legacy)
    end
  end

  test "current checkpoints reject every missing or unexpected top-level field" do
    checkpoint = run_engine() |> Engine.dump_state() |> json_round_trip()

    Enum.each(Map.keys(checkpoint), fn key ->
      assert_raise ArgumentError,
                   ~r/unexpected or missing keys|invalid GEPA engine resume state/,
                   fn ->
                     run_engine(resume_state: Map.delete(checkpoint, key))
                   end
    end)

    assert_raise ArgumentError, ~r/unexpected or missing keys/, fn ->
      run_engine(resume_state: Map.put(checkpoint, "obsolete", true))
    end
  end

  defp interrupt_checkpoint!(status, phase \\ nil) do
    owner = self()
    expected_status = Atom.to_string(status)
    expected_phase = if(phase, do: Atom.to_string(phase))

    assert_raise RuntimeError, "interrupt", fn ->
      run_engine(
        checkpoint_fn: fn checkpoint ->
          case checkpoint["pending_proposal_batch"] do
            %{"status" => ^expected_status, "phase" => checkpoint_phase}
            when is_nil(expected_phase) or checkpoint_phase == expected_phase ->
              send(owner, {:checkpoint, checkpoint})
              raise "interrupt"

            _ ->
              :ok
          end
        end
      )
    end

    assert_receive {:checkpoint, checkpoint}
    checkpoint
  end

  defp run_engine(overrides \\ []) do
    {proposer, overrides} =
      Keyword.pop(overrides, :proposer, fn _candidate, _component, _records, iteration ->
        "proposal-#{iteration}"
      end)

    {delays, overrides} = Keyword.pop(overrides, :delays, %{})
    {owner, overrides} = Keyword.pop(overrides, :owner, self())

    opts =
      Keyword.merge(
        [
          max_iterations: 2,
          minibatch_size: 1,
          proposal_concurrency: 2,
          candidate_selection_strategy: :current_best,
          max_metric_calls: 20,
          seed: 3
        ],
        overrides
      )

    Engine.run(
      %FixtureAdapter{owner: owner, delays: delays},
      %{main: "base"},
      [{:train, 0}, {:train, 1}],
      [:validation],
      proposer,
      opts
    )
  end

  defp callback_messages(acc \\ []) do
    receive do
      {:callback, _, _} = message -> callback_messages(acc ++ [message])
      {:callback, _, _, _} = message -> callback_messages(acc ++ [message])
    after
      0 -> acc
    end
  end

  defp receive_evaluation_starts(0, acc), do: Enum.reverse(acc)

  defp receive_evaluation_starts(count, acc) do
    receive do
      {:evaluation_started, _phase, :validation, _pid} ->
        receive_evaluation_starts(count, acc)

      {:evaluation_started, _phase, _id, _pid} = event ->
        receive_evaluation_starts(count - 1, [event | acc])
    after
      1_000 -> flunk("expected #{count} more evaluation starts")
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
