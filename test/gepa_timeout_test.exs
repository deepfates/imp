defmodule DSEx.Optimizer.GEPATimeoutTest do
  use ExUnit.Case, async: false

  defmodule ErrorCallback do
    @behaviour DSEx.Optimizer.GEPA.Callback

    @impl true
    def on_error(event, owner), do: send(owner, {:gepa_error, event.exception})
  end

  defmodule FixtureAdapter do
    @behaviour DSEx.Optimizer.GEPA.Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      score = if candidate.main == "base", do: 0.0, else: 1.0

      traces =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      DSEx.Optimizer.GEPA.Result.new(batch, List.duplicate(score, length(batch)),
        trajectories: traces,
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

  defp example do
    DSEx.example(question: "q", answer: "ok") |> DSEx.with_inputs(:question)
  end

  test "threads the optimizer timeout into trajectory evaluation and reports it" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Process.sleep(20)
          %{answer: "ok"}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    {_compiled, report} =
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
        generations: 0,
        timeout: 1
      )
      |> DSEx.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

    assert report.metadata.timeout == 1
    assert [%{candidate_id: "baseline", diagnostics: ["{:task_exit, :timeout}"]}] = report.errors
  end

  test "accepts infinity and rejects invalid timeout values" do
    assert %DSEx.Optimizer.GEPA{timeout: :infinity, proposal_timeout: :infinity} =
             DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: :infinity)

    assert %DSEx.Optimizer.GEPA{timeout: 100, proposal_timeout: 5} =
             DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
               timeout: 100,
               proposal_timeout: 5
             )

    assert_raise ArgumentError, ~r/invalid value for :timeout option/, fn ->
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: -1)
    end

    assert_raise ArgumentError, ~r/invalid value for :proposal_timeout option/, fn ->
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), proposal_timeout: -1)
    end
  end

  test "hung reflection LM inherits proposal timeout, is cancelled, and consumes its call" do
    owner = self()
    baseline = MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor))

    program =
      DSEx.predict("question -> answer",
        lm: %{
          module: DSEx.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "wrong"} end]
        }
      )

    reflection_lm = fn _messages, opts ->
      send(owner, {:reflection_lm_started, self(), opts})
      Process.sleep(:infinity)
    end

    started_at = System.monotonic_time(:millisecond)

    {_compiled, report} =
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
        generations: 1,
        timeout: 20,
        reflection_lm: reflection_lm,
        max_reflection_calls: 1,
        callbacks: [{ErrorCallback, owner}]
      )
      |> DSEx.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_receive {:reflection_lm_started, worker, []}
    assert_receive {:gepa_error, :timeout}
    assert elapsed < 1_000
    assert report.metadata.proposal_timeout == 20
    assert report.metadata.reflection_calls == 1
    assert report.metadata.max_reflection_calls == 1
    assert report.metadata.rejected_candidates == 1

    assert eventually(fn ->
             not Process.alive?(worker) and
               MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)) == baseline
           end)
  end

  test "interrupted sequential reflection resumes with conservative spend and no replay" do
    owner = self()

    prepared =
      interrupt_sequential_checkpoint!(owner, "prepared", "reflection")

    assert [%{"reflection_calls" => 1}] =
             Enum.filter(prepared["budget_ledger"], &String.starts_with?(&1["id"], "reflection:"))

    assert prepared["budget"]["reflection_calls"] == 0

    started =
      interrupt_sequential_checkpoint!(owner, "started", "reflection")

    assert [%{"reflection_calls" => 1}] =
             Enum.filter(started["budget_ledger"], &String.starts_with?(&1["id"], "reflection:"))

    resumed_prepared = run_sequential_engine(resume_state: prepared)
    assert resumed_prepared.budget.reflection_calls == 1
    assert resumed_prepared.iteration == 1

    resumed_started =
      run_sequential_engine(
        resume_state: started,
        proposer: fn _, _, _, _, _ ->
          send(owner, :replayed_ambiguous_reflection)
          "must-not-run"
        end
      )

    assert resumed_started.budget.reflection_calls == 1
    assert resumed_started.iteration == 1

    assert [%{reason: {:proposal_error, {:interrupted_reflection, :ambiguous_external_effects}}}] =
             resumed_started.rejected

    refute_receive :replayed_ambiguous_reflection
  end

  defp interrupt_sequential_checkpoint!(owner, status, phase) do
    assert_raise RuntimeError, "interrupt", fn ->
      run_sequential_engine(
        checkpoint_fn: fn checkpoint ->
          case checkpoint["pending_proposal_batch"] do
            %{"status" => ^status, "phase" => ^phase} ->
              send(owner, {:sequential_checkpoint, checkpoint})
              raise "interrupt"

            _other ->
              :ok
          end
        end
      )
    end

    assert_receive {:sequential_checkpoint, checkpoint}
    checkpoint
  end

  defp run_sequential_engine(overrides) do
    {proposer, overrides} =
      Keyword.pop(
        overrides,
        :proposer,
        fn _candidate, _component, _records, _iteration, _metadata -> "proposal" end
      )

    opts =
      Keyword.merge(
        [
          max_iterations: 1,
          minibatch_size: 4,
          proposal_concurrency: 1,
          candidate_selection_strategy: :current_best,
          acceptance_policy: :equal_or_better
        ],
        overrides
      )

    DSEx.Optimizer.GEPA.Engine.run(
      %FixtureAdapter{},
      %{main: "base"},
      Enum.to_list(0..3),
      [:validation],
      proposer,
      opts
    )
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
end
