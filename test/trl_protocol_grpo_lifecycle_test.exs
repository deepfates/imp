defmodule Imp.TRLProtocolGRPOLifecycleTest do
  use ExUnit.Case

  alias Imp.Clients.{TrainingJob, TRLArtifact, TRLDeployment, TRLLM, TRLProtocol, TRLTrainer}
  alias Imp.Optimizer.TrainingResult

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-trl-conformance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    server = start_supervised!({Imp.Test.TRLConformanceServer, root: root})
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, server: server}
  end

  test "validation selects an earlier content-verified trained artifact", context do
    program =
      Imp.predict("question -> answer",
        lm: %Imp.Test.TRLConformanceLM{model: "local/no-model-policy"}
      )

    scores = %{0 => 1.0, 1 => 0.5}

    optimizer =
      Imp.Optimizer.GRPO.new(
        fn _example, _prediction -> 1.0 end,
        trainer: %Imp.Test.TRLConformanceTrainer{server: context.server},
        validation_fn: fn _program, _dataset, %{step: step} -> {:ok, Map.fetch!(scores, step)} end,
        checkpoint_selection: :best_validation,
        num_train_steps: 2,
        num_steps_for_val: 1,
        num_rollouts_per_grpo_step: 2,
        status_poll_interval_ms: 0
      )

    rows = [Imp.example(question: "alpha", answer: "alpha") |> Imp.with_inputs(:question)]

    assert {:ok, result} = Imp.train(program, optimizer, rows, validation: rows)
    assert result.job.result_model == Path.join(context.root, "artifacts/step-1")
    assert result.job.metadata.selected_validation_step == 1
    assert result.job.metadata.selected_validation_score == 1.0
    assert result.job.metadata.final_trained_model == Path.join(context.root, "artifacts/step-2")

    assert Enum.map(result.job.metadata.validation_history, &{&1.step, &1.score}) ==
             [{1, 1.0}, {2, 0.5}]

    assert Imp.ProgramAccess.lm(result.program).model == result.job.result_model
    assert {:ok, manifest} = TRLArtifact.verify_job(result.job)
    assert manifest["trainer_step"] == 1

    job_path = Path.join(context.root, "selected-job.json")
    assert :ok = TrainingJob.save!(result.job, job_path)
    loaded = TrainingJob.read!(job_path)
    assert loaded.result_model == result.job.result_model

    assert Enum.map(loaded.metadata["validation_history"], &{&1["step"], &1["score"]}) ==
             [{1, 1.0}, {2, 0.5}]
  end

  test "public GRPO produces an ordered durable artifact and a fresh process executes it",
       context do
    checkpoint = Path.join(context.root, "imp-grpo.json")

    program =
      Imp.predict("question -> answer",
        lm: %Imp.Test.TRLConformanceLM{model: "local/no-model-policy"}
      )

    optimizer =
      Imp.Optimizer.GRPO.new(
        Imp.Optimizer.GRPO.Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
          id: "trl-conformance-reward-v1",
          config: %{"value" => 1.0}
        ),
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
    worker_script = Path.join(context.root, "fake-deployment-worker.py")
    deployment_root = Path.join(context.root, "deployment-runtime")
    model_path = Path.join(context.root, "base-model")

    portable = Imp.predict("question -> answer", lm: Imp.req_llm("openai:portable-base"))
    :ok = Imp.save!(portable, base_program_path)
    :ok = TrainingJob.save!(job, job_path)
    :ok = File.mkdir_p(model_path)
    :ok = File.write(worker_script, fake_deployment_worker())

    base_trainer =
      TRLTrainer.new(
        python: System.find_executable("python3"),
        model_path: model_path,
        root: deployment_root,
        worker_script: worker_script,
        contract_path: Path.expand("../priv/trl_worker/qwen-one-update-contract.json", __DIR__)
      )

    assert {:ok, %{kind: :base} = base_deployment} = TRLDeployment.start_base(base_trainer)
    assert base_deployment.lm.generation_mode == :greedy
    base_program = Imp.ProgramAccess.put_lm(portable, base_deployment.lm)

    assert {:ok, base_prediction} =
             Imp.call(base_program, %{question: "Does base evaluation work?"})

    assert Imp.get(base_prediction, :answer) == "served exact base"
    assert :ok = TRLDeployment.stop(base_deployment)

    script = """
    job = Imp.Clients.TrainingJob.read!(#{inspect(job_path)})
    program = Imp.read!(#{inspect(base_program_path)})
    trainer = Imp.Clients.TRLTrainer.new(
      python: #{inspect(System.find_executable("python3"))},
      model_path: #{inspect(model_path)},
      root: #{inspect(deployment_root)},
      worker_script: #{inspect(worker_script)},
      contract_path: #{inspect(Path.expand("../priv/trl_worker/qwen-one-update-contract.json", __DIR__))}
    )
    {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, program, trainer: trainer)
    {:ok, prediction} = Imp.call(rebound, %{question: "Does the saved adapter answer?"})
    IO.puts("FRESH_MODEL=" <> Imp.ProgramAccess.lm(rebound).model)
    IO.puts("FRESH_SHA=" <> Imp.ProgramAccess.get_metadata(rebound, :training_artifact).artifact_sha256)
    IO.puts("FRESH_ANSWER=" <> Imp.get(prediction, :answer))
    :ok = Imp.Clients.TRLDeployment.stop(job)
    """

    {output, 0} =
      System.cmd("mix", ["run", "-e", script], env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert output =~ "FRESH_MODEL=#{job.result_model}"
    assert output =~ "FRESH_SHA=#{job.metadata.artifact_sha256}"
    assert output =~ "FRESH_ANSWER=served verified adapter"

    assert {:error, :trl_deployment_program_not_portable} =
             TrainingJob.rebind(job, portable,
               trainer: :untrusted,
               path: Path.join(context.root, "must-not-be-written.json")
             )

    assert {:error, :trl_deployment_worker_not_running} =
             TrainingJob.rebind(job, portable,
               lm: %TRLLM{
                 model: job.result_model,
                 worker_key: {:missing_deployment, make_ref()},
                 artifact_sha256: job.metadata.artifact_sha256
               }
             )

    assert {:error, :trl_deployment_runtime_conflict} =
             TrainingJob.rebind(job, portable, lm: Imp.req_llm("openai:any"), trainer: :any)

    extra_path = Path.join(job.result_model, "unlisted.bin")
    File.write!(extra_path, "not in the manifest")

    assert {:error, {:trl_artifact_inventory_mismatch, _expected, _actual}} =
             TRLArtifact.verify_job(job)

    File.rm!(extra_path)

    weights_path = Path.join(job.result_model, "adapter.safetensors")
    <<first, rest::binary>> = File.read!(weights_path)
    File.write!(weights_path, <<rem(first + 1, 256), rest::binary>>)

    assert {:error, {:trl_artifact_file_digest_mismatch, "adapter.safetensors"}} =
             TRLArtifact.verify_job(job)
  end

  defp fake_deployment_worker do
    ~S'''
    import argparse, json, pathlib, struct, sys

    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--contract", required=True)
    args = parser.parse_args()

    def read_frame():
        header = sys.stdin.buffer.read(4)
        if not header:
            return None
        length = struct.unpack(">I", header)[0]
        return json.loads(sys.stdin.buffer.read(length))

    def write_frame(value):
        body = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
        sys.stdout.buffer.flush()

    while (request := read_frame()) is not None:
        op = request.get("op")
        if op == "initialize":
            result = {
                "model": "local/no-model-policy",
                "model_path": args.model,
                "base_model_sha256": "sha256:base",
            }
        elif op == "deploy_base":
            result = {
                "model": request["model"],
                "artifact_sha256": request["artifact_sha256"],
                "adapter_sha256": None,
            }
        elif op == "deploy_artifact":
            observation = json.loads((pathlib.Path(request["artifact_path"]) / "trl-observation.json").read_text())
            result = {
                "model": request["artifact_path"],
                "artifact_sha256": request["artifact_sha256"],
                "adapter_sha256": observation["trainable_after_sha256"],
            }
        elif op == "generate":
            answer = "served exact base" if result["artifact_sha256"] == "sha256:base" else "served verified adapter"
            result = {
                "completion": "[[ ## answer ## ]]\n" + answer + "\n\n[[ ## completed ## ]]\n",
                "model": result["model"],
                "artifact_sha256": result["artifact_sha256"],
                "adapter_sha256": result["adapter_sha256"],
                "generation_mode": request["generation_mode"],
            }
        else:
            write_frame({"ok": False, "error": {"accepted": False, "code": "unknown", "message": op}})
            continue
        write_frame({"ok": True, "result": result})
    '''
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
      Imp.Optimizer.GRPO.new(
        Imp.Optimizer.GRPO.Callback.reward(Imp.Test.StableGRPOCallbacks, :reward,
          id: "trl-crash-window-reward-v1",
          config: %{"value" => 1.0}
        ),
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
