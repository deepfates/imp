defmodule DSEx.Optimizer.MIPROv2.ResumeTest do
  use ExUnit.Case, async: false

  alias DSEx.Optimizer.{MIPROv2, Report}

  setup do
    state = start_supervised!({Agent, fn -> %{proposal_calls: 0, checkpoints: []} end})
    %{state: state}
  end

  test "JSON checkpoint resume matches an uninterrupted run without replaying setup", %{
    state: state
  } do
    {program, optimizer, trainset, valset} = fixture(state)

    uninterrupted =
      optimizer
      |> MIPROv2.compile(program, trainset, valset)
      |> Report.fetch()

    Agent.update(state, fn _ -> %{proposal_calls: 0, checkpoints: []} end)

    checkpoint_fn = fn checkpoint ->
      Agent.update(state, fn snapshot ->
        %{snapshot | checkpoints: snapshot.checkpoints ++ [checkpoint]}
      end)
    end

    paused =
      optimizer
      |> MIPROv2.compile(program, trainset, valset,
        max_trials: 2,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_trials == 2
    assert paused.candidate_count == 2

    state_after_pause = Agent.get(state, & &1)
    assert length(state_after_pause.checkpoints) == 3

    assert Enum.map(state_after_pause.checkpoints, fn checkpoint ->
             length(checkpoint["payload"]["state"]["trials"])
           end) == [0, 1, 2]

    resume_state = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()

    resumed =
      optimizer
      |> MIPROv2.compile(program, trainset, valset,
        resume_state: resume_state,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    state_after_resume = Agent.get(state, & &1)

    assert state_after_resume.proposal_calls == state_after_pause.proposal_calls
    assert length(state_after_resume.checkpoints) == 7
    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_trials == 6
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert resumed.metadata.full_evaluations == uninterrupted.metadata.full_evaluations
    assert resumed.metadata.search_policy == uninterrupted.metadata.search_policy
    assert resumed.metadata.evaluation_calls == uninterrupted.metadata.evaluation_calls
    assert Jason.encode!(resumed.metadata.resume_state)
  end

  test "resume rejects a different resolved dataset", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    changed_valset = [
      DSEx.example(question: "different", answer: "yes") |> DSEx.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/does not match the program, datasets, or search configuration/,
                 fn ->
                   MIPROv2.compile(optimizer, program, trainset, changed_valset,
                     resume_state: checkpoint
                   )
                 end
  end

  test "resume rejects a mutated checkpoint payload", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> put_in(["payload", "state", "evaluation_calls"], 99_999)

    assert_raise ArgumentError, ~r/checksum does not match its payload/, fn ->
      MIPROv2.compile(optimizer, program, trainset, valset, resume_state: checkpoint)
    end
  end

  test "run configuration matching excludes runtime callback captures", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)
    optimizer = %{optimizer | metric: captured_metric(state)}

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    replacement_state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{proposal_calls: 0, checkpoints: []} end},
          id: :replacement_callback_state
        )
      )

    {_program, rebound_optimizer, _trainset, _valset} = fixture(replacement_state)
    rebound_optimizer = %{rebound_optimizer | metric: captured_metric(replacement_state)}

    report =
      rebound_optimizer
      |> MIPROv2.compile(program, trainset, valset, resume_state: checkpoint, max_trials: 0)
      |> Report.fetch()

    assert report.metadata.resumed
    assert report.metadata.completed_trials == 1
  end

  defp captured_metric(state) do
    fn example, prediction ->
      _ = Agent.get(state, & &1.proposal_calls)
      DSEx.Metrics.exact_match(:answer).(example, prediction)
    end
  end

  defp fixture(state) do
    task_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "yes"} end]
    }

    prompt_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(
            state,
            &Map.update!(&1, :proposal_calls, fn count -> count + 1 end)
          )

          ["Answer consistently.", "Return yes.", "Use the demonstrations."]
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: task_lm)

    trainset =
      for index <- 1..3 do
        DSEx.example(question: "train #{index}", answer: "yes") |> DSEx.with_inputs(:question)
      end

    valset =
      for index <- 1..2 do
        DSEx.example(question: "val #{index}", answer: "yes") |> DSEx.with_inputs(:question)
      end

    optimizer =
      MIPROv2.new(DSEx.Metrics.exact_match(:answer),
        auto: nil,
        num_candidates: 3,
        num_trials: 6,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: true,
        minibatch_size: 1,
        minibatch_full_eval_steps: 2,
        prompt_lm: prompt_lm,
        startup_trials: 1,
        seed: 31
      )

    {program, optimizer, trainset, valset}
  end
end
