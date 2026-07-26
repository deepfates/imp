defmodule Imp.TRLProtocolGRPOLifecycleTest do
  use ExUnit.Case

  alias Imp.Clients.{TrainingJob, TRLProtocol}
  alias Imp.Optimizer.TrainingResult

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-trl-conformance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    server = start_supervised!({Imp.Test.TRLConformanceServer, root: root})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "public GRPO produces an ordered durable artifact and a fresh process rebinds it",
       context do
    checkpoint = Path.join(context.root, "imp-grpo.json")

    program =
      Imp.predict("question -> answer",
        lm: %Imp.Test.TRLConformanceLM{model: "local/no-model-policy"}
      )

    optimizer =
      Imp.Optimizer.GRPO.new(
        fn example, prediction ->
          if String.starts_with?(Imp.get(prediction, :answer), Imp.get(example, :question)),
            do: 1.0,
            else: 0.0
        end,
        trainer: %Imp.Test.TRLConformanceTrainer{server: context.server},
        num_train_steps: 2,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0,
        checkpoint_path: checkpoint
      )

    trainset = [Imp.example(question: "alpha", answer: "alpha") |> Imp.with_inputs(:question)]

    assert {:ok,
            %TrainingResult{
              status: :completed,
              program: trained,
              job: %TrainingJob{status: :succeeded} = job
            }} = Imp.train(program, optimizer, trainset)

    refute File.exists?(checkpoint)
    assert job.provider == :trl
    assert job.model == "local/no-model-policy"
    assert job.result_model == Path.join(context.root, "artifacts/step-2")
    assert job.metadata.method == :grpo
    assert job.metadata.artifact_sha256 =~ ~r/^sha256:/
    assert Imp.ProgramAccess.lm(trained).model == job.result_model

    snapshot = Imp.Test.TRLConformanceServer.snapshot(context.server)
    assert snapshot.step == 2
    assert map_size(snapshot.updates) == 2
    assert length(snapshot.receipts) == 2
    assert snapshot.session.status == :succeeded
    assert snapshot.session.pending_batch_ids == []
    assert snapshot.protocol["engine"] == TRLProtocol.engine_identity()
    assert length(snapshot.protocol["prompt_schedule"]["steps"]) == 2

    for %{update: update, receipt: receipt} <- Map.values(snapshot.updates) do
      assert :ok = TRLProtocol.validate(update)
      assert :ok = TRLProtocol.validate(receipt)
      assert length(update["groups"]) == 1
      assert length(hd(update["groups"])["samples"]) == 2

      for sample <- hd(update["groups"])["samples"] do
        assert length(sample["prompt_token_ids"]) == length(sample["prompt_mask"])
        assert length(sample["completion_token_ids"]) == length(sample["completion_mask"])
        assert length(sample["completion_token_ids"]) == length(sample["behavior_logprobs"])
      end
    end

    manifest =
      job.result_model |> Path.join("imp-trl-artifact.json") |> File.read!() |> Jason.decode!()

    assert :ok = TRLProtocol.validate(manifest)
    assert manifest["payload_sha256"] == job.metadata.artifact_sha256
    refute manifest["payload_sha256"] == snapshot.protocol["behavior_policy"]["artifact_sha256"]

    [first | _] = snapshot.updates |> Map.values() |> Enum.sort_by(& &1.update["trainer_step"])
    before_replay = Imp.Test.TRLConformanceServer.snapshot(context.server)

    assert {:ok, _session} =
             Imp.Test.TRLConformanceServer.submit_envelope(context.server, first.update)

    after_replay = Imp.Test.TRLConformanceServer.snapshot(context.server)
    assert after_replay.step == before_replay.step
    assert after_replay.receipts == before_replay.receipts
    assert after_replay.session == before_replay.session

    changed =
      first.update
      |> Map.drop(["type", "schema_version", "payload_sha256"])
      |> update_in(["groups", Access.at(0), "samples", Access.at(0), "reward"], &(&1 + 0.25))
      |> TRLProtocol.update!()

    assert {:error, :trl_protocol_replay_payload_mismatch} =
             Imp.Test.TRLConformanceServer.submit_envelope(context.server, changed)

    job_path = Path.join(context.root, "job.json")
    base_program_path = Path.join(context.root, "base-program.json")
    rebound_path = Path.join(context.root, "fresh-rebound.json")

    portable = Imp.predict("question -> answer", lm: Imp.req_llm("openai:portable-base"))
    :ok = Imp.save!(portable, base_program_path)
    :ok = TrainingJob.save!(job, job_path)

    script = """
    job = Imp.Clients.TrainingJob.load!(#{inspect(job_path)})
    program = Imp.load!(#{inspect(base_program_path)})
    {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, program, path: #{inspect(rebound_path)})
    IO.puts("FRESH_MODEL=" <> Imp.ProgramAccess.lm(rebound).model)
    IO.puts("FRESH_SHA=" <> Imp.ProgramAccess.get_metadata(rebound, :training_artifact).artifact_sha256)
    """

    {output, 0} =
      System.cmd("mix", ["run", "-e", script], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert output =~ "FRESH_MODEL=#{job.result_model}"
    assert output =~ "FRESH_SHA=#{job.metadata.artifact_sha256}"
    assert Imp.ProgramAccess.lm(Imp.load!(rebound_path)).model == job.result_model

    extra_path = Path.join(job.result_model, "unlisted.bin")
    File.write!(extra_path, "not in the manifest")

    assert {:error, {:trl_artifact_inventory_mismatch, _expected, _actual}} =
             TrainingJob.rebind(job, portable)

    File.rm!(extra_path)

    weights_path = Path.join(job.result_model, "adapter.safetensors")
    <<first, rest::binary>> = File.read!(weights_path)
    File.write!(weights_path, <<rem(first + 1, 256), rest::binary>>)

    assert {:error, {:trl_artifact_file_digest_mismatch, "adapter.safetensors"}} =
             TrainingJob.rebind(job, portable)
  end

  test "a crash-window response reconciles the durable receipt without repeating the update",
       context do
    root = Path.join(context.root, "crash-window")

    server =
      start_supervised!(%{
        id: {:trl_crash_server, System.unique_integer([:positive])},
        start:
          {Imp.Test.TRLConformanceServer, :start_link,
           [[root: root, failure_mode: :after_first_accept]]}
      })

    checkpoint = Path.join(root, "imp-grpo.json")

    program =
      Imp.predict("question -> answer",
        lm: %Imp.Test.TRLConformanceLM{model: "local/no-model-policy"}
      )

    optimizer =
      Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
        trainer: %Imp.Test.TRLConformanceTrainer{server: server},
        num_train_steps: 1,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0,
        checkpoint_path: checkpoint
      )

    trainset = [Imp.example(question: "alpha", answer: "alpha") |> Imp.with_inputs(:question)]

    assert {:error,
            {:grpo_step_outcome_unknown, step_id, :trl_conformance_transport_lost_after_accept}} =
             Imp.train(program, optimizer, trainset)

    first = Imp.Test.TRLConformanceServer.snapshot(server)
    assert first.step == 1
    assert length(first.receipts) == 1
    assert Map.has_key?(first.updates, step_id)
    assert File.regular?(checkpoint)

    assert {:ok, %TrainingResult{status: :completed, job: %TrainingJob{} = job}} =
             Imp.train(program, optimizer, trainset)

    resumed = Imp.Test.TRLConformanceServer.snapshot(server)
    assert resumed.step == 1
    assert resumed.receipts == first.receipts
    assert map_size(resumed.updates) == 1
    assert job.metadata.artifact_sha256 == first.session.metadata.artifact_sha256
    refute File.exists?(checkpoint)
  end
end
