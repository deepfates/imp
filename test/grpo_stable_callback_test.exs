defmodule Imp.GRPOStableCallbackTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.GRPO.Callback

  setup do
    root = Path.join(System.tmp_dir!(), "imp-stable-grpo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "stable callbacks bind trusted code and JSON-safe config" do
    callback =
      Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
        id: "consumer-reward-v1",
        config: %{"value" => 1.0}
      )

    assert :ok = Callback.validate(callback, :reward)
    assert Callback.invoke(callback, %{}, %{}) == 1.0

    assert %{
             contract: "imp_grpo_callback_v1",
             kind: :reward,
             module: "Elixir.Imp.Test.StableGRPOCallbacks",
             function: "reward",
             id: "consumer-reward-v1",
             config_sha256: "sha256:" <> _digest
           } = Callback.identity(callback)

    assert {:error, :grpo_callback_config_digest_mismatch} =
             callback
             |> Map.put(:config, %{"value" => 0.0})
             |> Callback.validate(:reward)

    assert_raise ArgumentError, ~r/config must already be JSON-safe/, fn ->
      Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
        id: "bad-config-v1",
        config: %{value: 1.0}
      )
    end
  end

  test "durable GRPO rejects anonymous callbacks before trainer activity", %{root: root} do
    checkpoint = Path.join(root, "checkpoint.json")
    trainer = %Imp.Test.FileGRPOTrainer{root: root, runtime_mode: :normal}

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: trainer,
        checkpoint_path: checkpoint,
        num_train_steps: 1
      )

    assert {:error, :stable_grpo_callbacks_required_for_checkpoint} =
             Imp.train(program(), optimizer, trainset())

    assert Imp.Test.FileGRPOTrainer.events(root) == []
    refute File.exists?(checkpoint)
  end

  test "stable callback resumes in a fresh OS process and drift fails before reconciliation", %{
    root: root
  } do
    success_root = Path.join(root, "success")
    assert first = run_fresh(success_root, :hang_after_start, "reward-v1", 1.0)
    assert first =~ "reinforcement_callback_timeout"
    assert Imp.Test.FileGRPOTrainer.events(success_root) == ["start"]

    assert second = run_fresh(success_root, :normal, "reward-v1", 1.0)
    assert second =~ "status: :completed"

    assert Imp.Test.FileGRPOTrainer.events(success_root) == [
             "start",
             "reconcile",
             "step",
             "terminate"
           ]

    refute File.exists?(Path.join(success_root, "checkpoint.json"))

    assert File.read!(Path.join(success_root, "artifact/weights.fixture")) ==
             "stable-callback-resume\n"

    assert success_root |> Path.join("rewards.json") |> File.read!() |> Jason.decode!() == [
             1.0,
             1.0
           ]

    drift_root = Path.join(root, "drift")

    assert run_fresh(drift_root, :hang_after_start, "reward-v1", 1.0) =~
             "reinforcement_callback_timeout"

    assert run_fresh(drift_root, :normal, "reward-v1", 0.5) =~
             "GRPO session checkpoint identity mismatch"

    assert Imp.Test.FileGRPOTrainer.events(drift_root) == ["start"]

    identity_root = Path.join(root, "identity-drift")

    assert run_fresh(identity_root, :hang_after_start, "reward-v1", 1.0) =~
             "reinforcement_callback_timeout"

    assert run_fresh(identity_root, :normal, "reward-v2", 1.0) =~
             "GRPO session checkpoint identity mismatch"

    assert Imp.Test.FileGRPOTrainer.events(identity_root) == ["start"]
  end

  defp run_fresh(root, mode, id, value) do
    script = """
    root = #{inspect(root)}
    trainer = %Imp.Test.FileGRPOTrainer{root: root, runtime_mode: #{inspect(mode)}}
    callback = Imp.Optimizer.GRPO.Callback.reward(
      Imp.Test.StableGRPOCallbacks,
      :reward,
      id: #{inspect(id)},
      config: %{"value" => #{inspect(value)}}
    )
    program = Imp.predict("question -> answer", lm: %Imp.Test.TRLConformanceLM{model: "stable/no-model"})
    optimizer = Imp.Optimizer.GRPO.new(callback,
      trainer: trainer,
      checkpoint_path: Path.join(root, "checkpoint.json"),
      num_train_steps: 1,
      num_rollouts_per_grpo_step: 2,
      callback_timeout_ms: 100,
      status_poll_interval_ms: 0
    )
    trainset = [Imp.example(question: "q", answer: "ok") |> Imp.with_inputs(:question)]
    IO.inspect(Imp.train(program, optimizer, trainset), limit: :infinity)
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

  defp program,
    do:
      Imp.predict("question -> answer",
        lm: %Imp.Test.TRLConformanceLM{model: "stable/no-model"}
      )

  defp trainset,
    do: [Imp.example(question: "q", answer: "ok") |> Imp.with_inputs(:question)]
end
