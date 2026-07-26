defmodule Imp.Optimizer.SIMBA.ResumeTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{Report, SIMBA}

  test "JSON checkpoint resume matches an uninterrupted run and rebinds runtime callbacks" do
    uninterrupted_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_full)
    {program, optimizer, trainset, final_set} = fixture(uninterrupted_state)

    uninterrupted =
      optimizer
      |> SIMBA.compile(program, trainset, final_set)
      |> Report.fetch()

    pause_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_pause)
    {pause_program, pause_optimizer, pause_trainset, pause_final_set} = fixture(pause_state)

    checkpoint_fn = fn checkpoint ->
      Agent.update(
        pause_state,
        &Map.update!(&1, :checkpoints, fn values -> values ++ [checkpoint] end)
      )
    end

    paused =
      pause_optimizer
      |> SIMBA.compile(pause_program, pause_trainset, pause_final_set,
        max_steps: 1,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_steps == 1
    assert paused.best_score == nil
    assert paused.metadata.final_candidates == []

    after_pause = Agent.get(pause_state, & &1)
    assert length(after_pause.checkpoints) == 2

    assert Enum.map(after_pause.checkpoints, &get_in(&1, ["payload", "state", "completed_steps"])) ==
             [0, 1]

    assert get_in(Enum.at(after_pause.checkpoints, 0), ["payload", "state", "poisson_rng"]) !=
             get_in(Enum.at(after_pause.checkpoints, 1), ["payload", "state", "poisson_rng"])

    checkpoint = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()
    checkpoint_state = checkpoint["payload"]["state"]

    assert checkpoint["type"] == "imp_simba_run"
    assert checkpoint["schema_version"] == 1
    assert is_binary(checkpoint["payload_sha256"])
    assert checkpoint_state["population"]["policy"]
    assert checkpoint_state["poisson_rng"]
    assert checkpoint_state["order"]
    assert checkpoint_state["cursor"] >= 0
    assert checkpoint_state["trajectory_calls"] > 0
    assert checkpoint_state["candidate_evaluation_calls"] > 0
    assert checkpoint_state["final_evaluation_calls"] == 0
    assert checkpoint_state["final_evaluations"] == []
    assert is_list(checkpoint_state["errors"])

    resume_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_resume)
    {resume_program, resume_optimizer, resume_trainset, resume_final_set} = fixture(resume_state)

    resumed =
      resume_optimizer
      |> SIMBA.compile(resume_program, resume_trainset, resume_final_set,
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert Agent.get(pause_state, & &1) == after_pause
    assert Agent.get(resume_state, & &1).task_calls > 0

    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_steps == 3
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert resumed.errors == uninterrupted.errors
    assert resumed.metadata.trial_logs == uninterrupted.metadata.trial_logs
    assert resumed.metadata.final_candidates == uninterrupted.metadata.final_candidates
    assert resumed.metadata.search_policy == uninterrupted.metadata.search_policy
    assert resumed.metadata.trajectory_calls == uninterrupted.metadata.trajectory_calls

    assert resumed.metadata.candidate_evaluation_calls ==
             uninterrupted.metadata.candidate_evaluation_calls

    assert resumed.metadata.final_evaluation_calls ==
             uninterrupted.metadata.final_evaluation_calls

    assert resumed.metadata.budgets == uninterrupted.metadata.budgets
    assert Jason.encode!(resumed.metadata.resume_state)
  end

  test "resume rejects mutated payloads and incompatible datasets" do
    state = start_supervised!({Agent, fn -> counters() end})
    {program, optimizer, trainset, final_set} = fixture(state)

    checkpoint =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    mutated = put_in(checkpoint, ["payload", "state", "trajectory_calls"], 99_999)

    assert_raise ArgumentError, ~r/checksum does not match its payload/, fn ->
      SIMBA.compile(optimizer, program, trainset, final_set, resume_state: mutated)
    end

    changed_trainset =
      List.replace_at(
        trainset,
        0,
        Imp.example(question: "different", answer: "yes") |> Imp.with_inputs(:question)
      )

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(optimizer, program, changed_trainset, final_set,
                     resume_state: checkpoint
                   )
                 end

    changed_optimizer = %{optimizer | max_demos: 1}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(changed_optimizer, program, trainset, final_set,
                     resume_state: checkpoint
                   )
                 end
  end

  test "resume rejects task call policy drift before more search work" do
    state = start_supervised!({Agent, fn -> counters() end})
    {program, optimizer, trainset, final_set} = fixture(state)

    checkpoint =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    calls_before = Agent.get(state, & &1)
    changed = %{program | config: [temperature: 0.75], dynamic_adapter?: false}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(optimizer, changed, trainset, final_set,
                     resume_state: checkpoint,
                     max_steps: 0
                   )
                 end

    assert Agent.get(state, & &1) == calls_before
  end

  test "resume does not replay completed final evaluations" do
    interrupted_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_interrupted)
    {program, optimizer, trainset, final_set} = fixture(interrupted_state)

    checkpoint_fn = fn checkpoint ->
      Agent.update(
        interrupted_state,
        &Map.update!(&1, :checkpoints, fn values -> values ++ [checkpoint] end)
      )

      if length(checkpoint["payload"]["state"]["final_evaluations"]) == 1 do
        raise "simulated checkpoint interruption"
      end
    end

    assert_raise RuntimeError, "simulated checkpoint interruption", fn ->
      SIMBA.compile(optimizer, program, trainset, final_set, checkpoint_fn: checkpoint_fn)
    end

    checkpoint = interrupted_state |> Agent.get(&List.last(&1.checkpoints)) |> json_round_trip()
    assert length(checkpoint["payload"]["state"]["final_evaluations"]) == 1
    completed_final_calls = checkpoint["payload"]["state"]["final_evaluation_calls"]
    assert completed_final_calls == length(final_set)

    resumed_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_final_resume)

    {resumed_program, resumed_optimizer, resumed_trainset, resumed_final_set} =
      fixture(resumed_state)

    report =
      resumed_optimizer
      |> SIMBA.compile(resumed_program, resumed_trainset, resumed_final_set,
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert report.metadata.run_status == :complete

    assert Agent.get(resumed_state, & &1.task_calls) ==
             report.metadata.final_evaluation_calls - completed_final_calls
  end

  defp fixture(state) do
    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          Agent.update(state, &Map.update!(&1, :task_calls, fn count -> count + 1 end))
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout_id = Keyword.get(opts, :rollout_id, 0)

          if prompt =~ "Answer yes." or rem(rollout_id, 2) == 0,
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(state, &Map.update!(&1, :prompt_calls, fn count -> count + 1 end))

          %{
            discussion: "Prefer the successful trajectory.",
            module_advice: %{main: "Answer yes."}
          }
        end
      ]
    }

    initial_demo =
      Imp.example(question: "seed", answer: "yes") |> Imp.with_inputs(:question)

    program = Imp.predict("question -> answer", lm: task_lm, demos: [initial_demo])

    trainset =
      for index <- 1..4 do
        Imp.example(question: "train #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    final_set =
      for index <- 1..2 do
        Imp.example(question: "final #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    optimizer =
      SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 3,
        max_demos: 0,
        prompt_lm: prompt_lm,
        max_concurrency: 1,
        seed: 41
      )

    {program, optimizer, trainset, final_set}
  end

  defp counters, do: %{task_calls: 0, prompt_calls: 0, checkpoints: []}

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
