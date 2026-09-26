defmodule Imp.Optimizer.GEPATimeoutTest do
  use ExUnit.Case, async: false

  defmodule ErrorCallback do
    @behaviour Imp.Optimizer.GEPA.Callback

    @impl true
    def on_error(event, owner), do: send(owner, {:gepa_error, event.exception})
  end

  defmodule FixtureAdapter do
    @behaviour Imp.Optimizer.GEPA.Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      score = if candidate.main == "base", do: 0.0, else: 1.0

      traces =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Imp.Optimizer.GEPA.Result.new(batch, List.duplicate(score, length(batch)),
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
    Imp.example(question: "q", answer: "ok") |> Imp.with_inputs(:question)
  end

  test "threads the optimizer timeout into trajectory evaluation and reports it" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Process.sleep(40)
          %{answer: "ok"}
        end
      )

    program = Imp.predict("question -> answer", lm: lm)

    {_compiled, report} =
      Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
        generations: 0,
        timeout: 1
      )
      |> Imp.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

    assert report.metadata.timeout == 1
    assert [%{candidate_id: "baseline", diagnostics: ["{:task_exit, :timeout}"]}] = report.errors
  end

  test "one full validation deadline bounds 45 examples across effective-concurrency waves" do
    examples = List.duplicate(example(), 45)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Process.sleep(20)
          %{answer: "ok"}
        end
      )

    program = Imp.predict("question -> answer", lm: lm)
    started_at = System.monotonic_time(:millisecond)

    Imp.context([async_max_workers: 8], fn ->
      {_compiled, report} =
        Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
          generations: 0,
          max_concurrency: 32,
          timeout: 90
        )
        |> Imp.Optimizer.GEPA.compile_with_report(program, [example()], examples)

      assert report.metadata.max_concurrency == 32
    end)

    elapsed = System.monotonic_time(:millisecond) - started_at
    assert elapsed < 180
  end

  test "accepts infinity and rejects invalid timeout values" do
    assert %Imp.Optimizer.GEPA{timeout: :infinity, proposal_timeout: :infinity} =
             Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer), timeout: :infinity)

    assert %Imp.Optimizer.GEPA{timeout: 100, proposal_timeout: 5} =
             Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
               timeout: 100,
               proposal_timeout: 5
             )

    assert_raise ArgumentError, ~r/invalid value for :timeout option/, fn ->
      Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer), timeout: -1)
    end

    assert_raise ArgumentError, ~r/invalid value for :proposal_timeout option/, fn ->
      Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer), proposal_timeout: -1)
    end
  end

  test "hung reflection LM inherits proposal timeout, is cancelled, and consumes its call" do
    owner = self()
    baseline = MapSet.new(Task.Supervisor.children(Imp.UnlinkedTaskSupervisor))

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
      )

    reflection_lm =
      Imp.Test.FunLM.new(fn _messages, opts ->
        send(owner, {:reflection_lm_started, self(), opts})
        Process.sleep(:infinity)
      end)

    started_at = System.monotonic_time(:millisecond)

    {_compiled, report} =
      Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
        generations: 1,
        timeout: 20,
        reflection_lm: reflection_lm,
        max_reflection_calls: 1,
        raise_on_exception: false,
        callbacks: [{ErrorCallback, owner}]
      )
      |> Imp.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

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
               MapSet.new(Task.Supervisor.children(Imp.UnlinkedTaskSupervisor)) == baseline
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

  test "in-flight sequential full validation resumes as a conservatively charged rejection" do
    owner = self()

    assert_raise RuntimeError, "interrupt", fn ->
      run_sequential_engine(
        checkpoint_fn: fn checkpoint ->
          case checkpoint["pending_validation"] do
            %{"status" => "started", "target_candidate_id" => 1} ->
              send(owner, {:validation_checkpoint, checkpoint})
              raise "interrupt"

            _other ->
              :ok
          end
        end
      )
    end

    assert_receive {:validation_checkpoint, checkpoint}
    assert checkpoint["pending_validation"]["validation_ids"] == [0]
    assert checkpoint["pending_validation"]["metric_calls"] == 1
    assert checkpoint["pending_validation_integrity"]

    resumed = run_sequential_engine(resume_state: checkpoint)

    assert resumed.pending_validation == nil
    assert resumed.iteration == 1
    assert Enum.map(resumed.candidates, & &1.id) == [0]
    assert resumed.budget.full_evaluations == checkpoint["budget"]["full_evaluations"] + 1

    assert [%{reason: {:interrupted_validation, :ambiguous_external_effects}} = rejected] =
             resumed.rejected

    refute Map.has_key?(rejected, :validation_score)

    resumed_checkpoint = Imp.Optimizer.GEPA.Engine.dump_state(resumed)
    assert resumed_checkpoint["pending_validation"] == nil

    continued = run_sequential_engine(resume_state: resumed_checkpoint, max_iterations: 2)
    assert continued.iteration == 2
    assert Enum.map(continued.candidates, & &1.id) == [0, 1]
    assert Enum.find(continued.history, &(&1.iteration == 1)).status == :rejected
  end

  test "pre-authorization validation checkpoint resumes without a budget charge" do
    owner = self()

    assert_raise RuntimeError, "interrupt", fn ->
      run_sequential_engine(
        max_full_evaluations: 1,
        checkpoint_fn: fn checkpoint ->
          case checkpoint["pending_validation"] do
            %{"status" => "started", "target_candidate_id" => 1} ->
              send(owner, {:unauthorized_validation_checkpoint, checkpoint})
              raise "interrupt"

            _other ->
              :ok
          end
        end
      )
    end

    assert_receive {:unauthorized_validation_checkpoint, checkpoint}
    assert checkpoint["budget"]["full_evaluations"] == 1

    resumed =
      run_sequential_engine(
        resume_state: checkpoint,
        max_full_evaluations: 1
      )

    assert resumed.pending_validation == nil
    assert resumed.iteration == 1
    assert Enum.map(resumed.candidates, & &1.id) == [0]
    assert resumed.budget.full_evaluations == checkpoint["budget"]["full_evaluations"]

    assert [%{reason: {:interrupted_validation, :discarded_before_authorization}} = rejected] =
             resumed.rejected

    refute Map.has_key?(rejected, :validation_score)

    resumed_checkpoint = Imp.Optimizer.GEPA.Engine.dump_state(resumed)
    assert resumed_checkpoint["pending_validation"] == nil

    continued =
      run_sequential_engine(
        resume_state: resumed_checkpoint,
        max_iterations: 2,
        max_full_evaluations: 1
      )

    assert continued.iteration == 1
    assert Enum.map(continued.candidates, & &1.id) == [0]
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

    Imp.Optimizer.GEPA.Engine.run(
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
