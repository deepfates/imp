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
      minibatch? = batch_id(batch) != :validation
      phase = if(iteration > 0, do: :child, else: :parent)
      delay = if(minibatch?, do: Map.get(adapter.delays, {phase, batch_id(batch)}, 0), else: 0)

      if minibatch?,
        do: send(adapter.owner, {:evaluation_started, phase, batch_id(batch), self()})

      if delay == :infinity, do: Process.sleep(:infinity), else: Process.sleep(delay)

      if minibatch?,
        do: send(adapter.owner, {:evaluation_finished, phase, batch_id(batch), self()})

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

    assert [
             %{
               reason:
                 {:proposal_error,
                  {:proposal_exception, "ArgumentError", "sequential reflection failed"}}
             }
           ] =
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

  test "failure reasons are redacted when recorded and every checkpoint still resumes" do
    secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

    for {name, proposer} <- [
          secret_in_error: fn _candidate, _component, _records, iteration ->
            if iteration == 1, do: raise("bad key #{secret}"), else: "proposal-#{iteration}"
          end,
          secret_in_instruction: fn _candidate, _component, _records, iteration ->
            "proposal-#{iteration} key #{secret}"
          end
        ] do
      owner = self()

      run_engine(
        proposer: proposer,
        raise_on_exception: false,
        checkpoint_fn: fn dumped ->
          send(owner, {:checkpoint, dumped})
          :ok
        end
      )

      checkpoints = receive_checkpoints([])
      assert Enum.any?(checkpoints, &(&1["pending_proposal_batch"] != nil)), inspect(name)

      for checkpoint <- checkpoints do
        failures =
          [checkpoint["rejected"], checkpoint["history"], checkpoint["pending_proposal_batch"]]
          |> Jason.encode!()

        if name == :secret_in_error,
          do: refute(failures =~ "abcdefghijklmnop", inspect(name))

        # A batch started before the checkpoint is refused by design; every
        # other checkpoint resumes, the proposed text included as it was.
        try do
          resumed =
            run_engine(
              proposer: proposer,
              raise_on_exception: false,
              resume_state: json_round_trip(checkpoint)
            )

          assert resumed.iteration == 2
        rescue
          error in ArgumentError ->
            assert checkpoint["pending_proposal_batch"]["status"] == "started"
            assert Exception.message(error) =~ "ambiguous external effects"
        end
      end

      if name == :secret_in_error do
        assert Enum.any?(checkpoints, fn checkpoint ->
                 Enum.any?(checkpoint["rejected"] || [], &(Jason.encode!(&1) =~ "[REDACTED]"))
               end)
      else
        assert Enum.any?(checkpoints, &(Jason.encode!(&1) =~ "abcdefghijklmnop"))
      end
    end
  end

  defmodule EvaluationRecorder do
    @behaviour Imp.Optimizer.GEPA.Callback

    @impl true
    def on_evaluation_end(%{has_trajectories: true} = event, owner) do
      send(owner, {:evaluation_end, {event.iteration, event.candidate_idx, event.trajectories}})
    end

    def on_evaluation_end(_event, _owner), do: :ok

    @impl true
    def on_evaluation_start(event, owner) do
      questions = Enum.map(event.inputs, &Imp.Example.get(&1, :question))
      send(owner, {:evaluation_start, {event.iteration, event.parent_ids, questions}})
    end
  end

  test "a predict program resumes from every checkpoint to the uninterrupted result" do
    for profile <- [
          [execution_profile: :beam_native, generations: 3, proposal_concurrency: 2],
          [execution_profile: :gepa_v0_1_4_merge]
        ] do
      owner = self()
      checkpoint_fn = fn dumped -> send(owner, {:checkpoint, dumped}) && :ok end
      expected = compile_predict_program(profile, checkpoint_fn: checkpoint_fn)
      evaluations = receive_evaluations([])
      starts = receive_starts([])
      checkpoints = receive_checkpoints([])

      # The proposed instruction carries a digest of the reflection prompt, so
      # a resumed run that reflects on other records proposes other text.
      refute expected.best == Imp.Optimizer.GEPA.Candidate.from_program(predict_program())
      assert Enum.all?(Map.values(expected.best), &(&1 =~ "Always answer Paris"))

      # A prepared batch holds the parent's trajectories, which a resumed run
      # hands to the evaluation callbacks as the uninterrupted run did.
      assert Enum.any?(checkpoints, fn checkpoint ->
               match?(
                 %{"status" => "prepared", "contexts" => [%{"parent_result" => %{}} | _]},
                 checkpoint["pending_proposal_batch"]
               )
             end),
             inspect(profile)

      for checkpoint <- checkpoints,
          resume_state <- [checkpoint, json_round_trip(checkpoint)] do
        context =
          inspect({profile, checkpoint["iteration"], checkpoint["pending_proposal_batch"]})

        case {checkpoint["pending_proposal_batch"], checkpoint["pending_validation"]} do
          # Evaluation that started before the checkpoint is refused.
          {%{"status" => "started", "phase" => phase}, nil} when phase in ["parent", "child"] ->
            assert_raise ArgumentError, ~r/ambiguous external effects/, fn ->
              compile_predict_program(profile, resume_state: resume_state)
            end

          # Reflection that started before the checkpoint is charged as an
          # interrupted proposal, and a pending full validation is charged
          # and its candidate rejected; the run goes on from there.
          {%{"status" => "started", "phase" => "reflection"}, nil} ->
            resumed = compile_predict_program(profile, resume_state: resume_state)
            assert inspect(resumed.report.errors) =~ "interrupted_reflection", context

          {nil, %{}} ->
            resumed = compile_predict_program(profile, resume_state: resume_state)
            assert resumed.report.metadata.rejected_candidates >= 1, context

          {_prepared_or_none, nil} ->
            resumed = compile_predict_program(profile, resume_state: resume_state)
            assert {resumed.best, resumed.score} == {expected.best, expected.score}, context

            # Every evaluation the resumed run makes, the uninterrupted run
            # made: the same iteration, parent and examples.
            for start <- receive_starts([]), do: assert(start in starts, context)

            # Every evaluation with trajectories, a parent's the batch holds
            # included, reaches the callbacks as it did uninterrupted.
            for evaluation <- receive_evaluations([]),
                do: assert(evaluation in evaluations, context)
        end

        receive_evaluations([])
        receive_starts([])
      end
    end
  end

  # The fresh VM compiles the same fixture module, so its program and seed
  # candidate match the checkpoint's.
  @fresh_fixture """
  defmodule Imp.Test.GEPAFreshFixture do
    def run(opts) do
      answer = fn messages, _opts ->
        prompt = Enum.map_join(messages, "\\n", & &1.content)
        if prompt =~ "Always answer Paris", do: %{answer: "Paris"}, else: %{answer: "unknown"}
      end

      reflect = fn messages, _opts ->
        prompt = Enum.map_join(messages, "\\n", & &1.content)
        %{instruction: "Always answer Paris. " <> Integer.to_string(:erlang.phash2(prompt))}
      end

      examples =
        for question <- ["Capital of France?", "France's capital?", "Where is the Louvre?"] do
          Imp.example(question: question, answer: "Paris") |> Imp.Example.with_inputs(:question)
        end

      {compiled, report} =
        Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
          execution_profile: :beam_native,
          generations: 3,
          proposal_concurrency: 2,
          reflection_lm: Imp.LM.Static.new(handler: reflect),
          max_metric_calls: 24,
          seed: 5
        )
        |> Imp.Optimizer.GEPA.compile_with_report(
          Imp.predict("question -> answer", lm: Imp.LM.Static.new(handler: answer)),
          examples,
          Enum.take(examples, 2),
          opts
        )

      Enum.join([Map.fetch!(Imp.Optimizer.GEPA.Candidate.from_program(compiled), :main), report.best_score], " | ")
    end
  end
  """

  @tag :tmp_dir
  test "a checkpoint holding a prepared batch resumes in a fresh VM", %{tmp_dir: tmp_dir} do
    fixture_path = Path.join(tmp_dir, "fixture.exs")
    File.write!(fixture_path, @fresh_fixture)
    Code.require_file(fixture_path)

    owner = self()

    uninterrupted =
      apply(Imp.Test.GEPAFreshFixture, :run, [
        [checkpoint_fn: fn dumped -> send(owner, {:checkpoint, dumped}) && :ok end]
      ])

    checkpoint =
      receive_checkpoints([])
      |> Enum.filter(fn checkpoint ->
        match?(
          %{"status" => "prepared", "contexts" => [%{"parent_result" => %{}} | _]},
          checkpoint["pending_proposal_batch"]
        )
      end)
      |> List.last()

    path = Path.join(tmp_dir, "checkpoint.json")
    File.write!(path, Jason.encode!(checkpoint))

    # The fresh VM loads no GEPA module ahead of the resume, so the checkpoint
    # loader has to load the modules whose atoms it decodes.
    expression = """
    {:ok, _} = Application.ensure_all_started(:imp)
    [fixture, checkpoint] = System.argv()
    Code.require_file(fixture)
    resume_state = checkpoint |> File.read!() |> Jason.decode!()
    IO.puts("resumed " <> Imp.Test.GEPAFreshFixture.run(resume_state: resume_state))
    """

    args =
      "_build/test/lib/*/ebin"
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])
      |> Kernel.++(["-e", expression, fixture_path, path])

    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "resumed #{uninterrupted}"
  end

  defp compile_predict_program(profile, compile_opts) do
    reflect = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      %{instruction: "Always answer Paris. #{:erlang.phash2(prompt)}"}
    end

    examples =
      for question <- ["Capital of France?", "France's capital?", "Where is the Louvre?"] do
        Imp.example(question: question, answer: "Paris") |> Imp.Example.with_inputs(:question)
      end

    {compiled, report} =
      Imp.Optimizer.GEPA.new(
        Imp.Metrics.exact_match(:answer),
        profile ++
          [
            reflection_lm: Imp.LM.Static.new(handler: reflect),
            callbacks: [{EvaluationRecorder, self()}],
            max_metric_calls: 24,
            seed: 5
          ]
      )
      |> Imp.Optimizer.GEPA.compile_with_report(
        predict_program(),
        examples,
        Enum.take(examples, 2),
        compile_opts
      )

    %{
      best: Imp.Optimizer.GEPA.Candidate.from_program(compiled),
      score: report.best_score,
      report: report
    }
  end

  defp receive_starts(acc) do
    receive do
      {:evaluation_start, start} -> receive_starts([start | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp receive_evaluations(acc) do
    receive do
      {:evaluation_end, evaluation} -> receive_evaluations([evaluation | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp predict_program do
    answer = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      if prompt =~ "Always answer Paris", do: %{answer: "Paris"}, else: %{answer: "unknown"}
    end

    Imp.predict("question -> answer", lm: Imp.LM.Static.new(handler: answer))
  end

  defp receive_checkpoints(acc) do
    receive do
      {:checkpoint, dumped} -> receive_checkpoints([dumped | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
             Imp.Optimizer.GEPA.new(metric,
               execution_profile: :beam_native,
               proposal_concurrency: :auto
             )

    assert_raise ArgumentError, ~r/invalid value for :proposal_concurrency option/, fn ->
      Imp.Optimizer.GEPA.new(metric, execution_profile: :beam_native, proposal_concurrency: 0)
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
