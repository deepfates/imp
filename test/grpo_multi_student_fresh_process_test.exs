defmodule GRPOMultiStudentFreshProcessTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.TrainingJob

  # Every trainer callback in these fresh BEAMs runs under this bound, including
  # the first `start_reinforcement`, which loads modules from disk and on a cold
  # machine can take hundreds of milliseconds. Only the hung step is meant to reach
  # the bound, and it never returns, so the bound needs only to exceed an
  # ordinary callback.
  @callback_timeout_ms 3_000

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-grpo-multi-fresh-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "fresh BEAM resumes only the active student and preserves distinct portable results", %{
    root: root
  } do
    first =
      run_fresh(root,
        mode: {:hang_after_step, "fresh-base-b"},
        reward_id: "fresh-multi-reward-v1",
        reward: 1.0
      )

    assert first =~ "grpo_step_outcome_unknown"
    assert first =~ "reinforcement_callback_timeout"

    first_events = [
      "start fresh-base-a",
      "step fresh-base-a",
      "terminate fresh-base-a",
      "start fresh-base-b",
      "step fresh-base-b"
    ]

    assert Imp.Test.FileMultiStudentGRPOTrainer.events(root) == first_events
    assert File.regular?(Path.join(root, "checkpoint.json"))

    topology_drift =
      run_fresh(root,
        mode: :normal,
        reward_id: "fresh-multi-reward-v1",
        reward: 1.0,
        second_model: "fresh-base-c"
      )

    assert topology_drift =~ "grpo_multi_student_checkpoint_identity_mismatch"
    assert Imp.Test.FileMultiStudentGRPOTrainer.events(root) == first_events

    config_drift =
      run_fresh(root,
        mode: :normal,
        reward_id: "fresh-multi-reward-v1",
        reward: 0.5
      )

    assert config_drift =~ "grpo_multi_student_checkpoint_identity_mismatch"
    assert Imp.Test.FileMultiStudentGRPOTrainer.events(root) == first_events

    second =
      run_fresh(root,
        mode: :normal,
        reward_id: "fresh-multi-reward-v1",
        reward: 1.0,
        save_result?: true
      )

    assert second =~ "status: :completed"

    events = Imp.Test.FileMultiStudentGRPOTrainer.events(root)
    assert Enum.take(events, 5) == first_events
    assert Enum.count(events, &String.starts_with?(&1, "start ")) == 2
    assert Enum.count(events, &String.starts_with?(&1, "step ")) == 2
    assert Enum.count(events, &(&1 == "terminate fresh-base-a")) == 1
    assert List.last(events) == "terminate fresh-base-b"
    assert Enum.at(events, -2) =~ ~r/^reconcile grpo:/

    refute File.exists?(Path.join(root, "checkpoint.json"))

    refute Enum.any?(File.ls!(root), &String.starts_with?(&1, "checkpoint.json.student-"))

    first_groups = Imp.Test.FileMultiStudentGRPOTrainer.groups(root, "fresh-base-a")
    second_groups = Imp.Test.FileMultiStudentGRPOTrainer.groups(root, "fresh-base-b")
    assert MapSet.new(Enum.map(first_groups, & &1.predictor)) == MapSet.new([:first])
    assert MapSet.new(Enum.map(second_groups, & &1.predictor)) == MapSet.new([:second])

    summary = root |> Path.join("result.json") |> File.read!() |> Jason.decode!()
    assert summary["job_is_nil"]
    assert summary["job_count"] == 2
    assert summary["job_models"] == ["fresh-base-a", "fresh-base-b"]
    assert summary["job_predictors"] == [["first"], ["second"]]
    assert summary["program_models"] == summary["result_models"]
    assert length(Enum.uniq(summary["result_models"])) == 2

    program =
      root
      |> Path.join("final-program.json")
      |> Imp.Test.MultiStudentGRPOProgram.load!()

    assert program.first.lm.model == Enum.at(summary["result_models"], 0)
    assert program.second.lm.model == Enum.at(summary["result_models"], 1)
    assert {:ok, prediction} = Imp.call(program, %{question: "fresh process"})
    assert Imp.get(prediction, :first_answer) == "one"
    assert Imp.get(prediction, :second_answer) == "two"

    jobs =
      for index <- 0..1 do
        root |> Path.join("job-#{index}.json") |> TrainingJob.read!()
      end

    assert Enum.map(jobs, & &1.model) == summary["job_models"]
    assert Enum.map(jobs, & &1.result_model) == summary["result_models"]
    assert Enum.all?(jobs, &(&1.status == :succeeded))
  end

  defp run_fresh(root, opts) do
    mode = Keyword.fetch!(opts, :mode)
    reward_id = Keyword.fetch!(opts, :reward_id)
    reward = Keyword.fetch!(opts, :reward)
    second_model = Keyword.get(opts, :second_model, "fresh-base-b")
    save_result? = Keyword.get(opts, :save_result?, false)

    script = """
    root = #{inspect(root)}
    trainer = %Imp.Test.FileMultiStudentGRPOTrainer{
      root: root,
      runtime_mode: #{inspect(mode)}
    }
    callback = Imp.Optimizer.GRPO.Callback.reward(
      Imp.Test.StableGRPOCallbacks,
      :reward,
      id: #{inspect(reward_id)},
      config: %{"value" => #{inspect(reward)}}
    )
    program = Imp.Test.MultiStudentGRPOProgram.new(second_model: #{inspect(second_model)})
    optimizer = Imp.Optimizer.GRPO.new(callback,
      trainer: trainer,
      checkpoint_path: Path.join(root, "checkpoint.json"),
      num_train_steps: 1,
      num_rollouts_per_grpo_step: 2,
      callback_timeout_ms: #{@callback_timeout_ms},
      status_poll_interval_ms: 0
    )
    trainset = [
      Imp.example(question: "q", first_answer: "one", second_answer: "two")
      |> Imp.with_inputs(:question)
    ]
    result = Imp.train(program, optimizer, trainset)

    if #{inspect(save_result?)} do
      {:ok, training_result} = result
      :ok = Imp.Test.MultiStudentGRPOProgram.save!(
        training_result.program,
        Path.join(root, "final-program.json")
      )

      Enum.with_index(training_result.jobs)
      |> Enum.each(fn {job, index} ->
        :ok = Imp.Clients.TrainingJob.save!(job, Path.join(root, "job-\#{index}.json"))
      end)

      predictors = Imp.ProgramParameters.predictors(training_result.program)
      summary = %{
        job_is_nil: is_nil(training_result.job),
        job_count: length(training_result.jobs),
        job_models: Enum.map(training_result.jobs, & &1.model),
        result_models: Enum.map(training_result.jobs, & &1.result_model),
        job_predictors: Enum.map(training_result.jobs, & &1.metadata.predictors),
        program_models: Enum.map(predictors, & &1.predictor.lm.model)
      }
      File.write!(Path.join(root, "result.json"), Jason.encode!(summary, pretty: true), [:sync])
    end

    IO.inspect(result, limit: :infinity)
    """

    {output, 0} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", "-e", script],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    output
  end
end
