defmodule Imp.Clients.MLXLMBetterTogetherTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.{MLXLMTrainer, Trainer, TrainingJob}
  alias Imp.Optimizer.{BetterTogether, BootstrapFinetune, TrainingJobAdoption, TrainingResult}

  @revision "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"

  defmodule ObservePromptContinuation do
    @behaviour Imp.Optimizer

    defstruct [:owner]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner}, program, _opts) do
      {:ok, prediction} = Imp.call(program, %{question: "frozen continuation probe"})
      lm = Imp.ProgramAccess.lm(program)

      send(owner, {
        :prompt_step_observed,
        Imp.Prediction.get(prediction, :answer),
        lm.model.id,
        Imp.ProgramAccess.get_metadata(program, :training_artifacts) ||
          List.wrap(Imp.ProgramAccess.get_metadata(program, :training_artifact))
      })

      {:ok,
       Imp.Optimizer.InstructionSearch.put_instruction(
         program,
         "Keep using the verified trained model."
       )}
    end
  end

  defmodule DeterministicBaseLM do
    def generate_text(model, messages, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "deterministic-base",
         model: model,
         context: ReqLLM.Context.new(messages),
         message:
           ReqLLM.Context.assistant("[[ ## answer ## ]]\nbase-behavior\n\n[[ ## completed ## ]]")
       }}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "imp-mlx-better-#{System.unique_integer([:positive])}")
    model_path = Path.join([root, "model", @revision])
    File.mkdir_p!(model_path)
    File.write!(Path.join(model_path, "behavior.txt"), "base-behavior\n", [:sync])

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, model_path: model_path}
  end

  test "ordinary BetterTogether weight then prompt continuation calls the fused model", context do
    port = available_port()
    signature = Imp.signature("question -> answer")

    trainer =
      MLXLMTrainer.new(
        root: Path.join(context.root, "runs"),
        model_path: context.model_path,
        model_revision: @revision,
        signature: signature,
        runner: &successful_runner/3,
        validation_fraction: 0,
        iters: 1,
        save_every: 1,
        server_executable: System.find_executable("python3"),
        server_executable_args: [Path.expand("support/fake_mlx_server.py", __DIR__)],
        server_port: port,
        server_startup_timeout: 5_000
      )

    base_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "base-behavior"} end)

    student = Imp.predict(signature, lm: base_lm)

    trainset = [
      Imp.example(question: "training probe", answer: "base-behavior")
      |> Imp.with_inputs([:question])
    ]

    metric = fn _example, _prediction -> 1.0 end

    optimizer =
      BetterTogether.new(metric, %{
        w:
          BootstrapFinetune.new(metric,
            trainer: trainer,
            max_demos: 1,
            num_threads: 1
          ),
        p: %ObservePromptContinuation{owner: self()}
      })

    compiled =
      BetterTogether.compile(optimizer, student, trainset, nil,
        strategy: [:w, :p],
        valset_ratio: 0,
        shuffle_trainset_between_steps: false,
        training_poll_interval: 0
      )

    assert_received {:prompt_step_observed, "trained-behavior", fused_path, [artifact]}
    assert fused_path == Path.expand(artifact.result_model)
    assert is_binary(artifact.artifact_sha256)

    assert Imp.ProgramAccess.lm(compiled).model.id == fused_path

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Keep using the verified trained model."

    assert {:ok, prediction} = Imp.call(compiled, %{question: "post-composition probe"})
    assert Imp.Prediction.get(prediction, :answer) == "trained-behavior"

    saved_path = Path.join(context.root, "better-together-program.json")
    :ok = Imp.save!(compiled, saved_path)
    loaded = Imp.read!(saved_path)
    assert model_id(Imp.ProgramAccess.lm(loaded)) == fused_path

    stop_job = %Imp.Clients.TrainingJob{result_model: fused_path}
    assert :ok = Imp.Clients.MLXLMDeployment.stop(stop_job)

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.selected_strategy == "w -> p"
    refute report.metadata.compilation_error_occurred
  end

  test "adopts a verified completed job without training and survives fresh save-load", context do
    parent = self()

    runner = fn executable, argv, opts ->
      send(parent, {:artifact_build, executable, argv})
      successful_runner(executable, argv, opts)
    end

    {job, program, trainset} = completed_job_fixture(context, runner)
    assert_received {:artifact_build, _, training_argv}
    assert "--train" in training_argv
    assert_received {:artifact_build, _, fusion_argv}
    assert "--save-path" in fusion_argv

    adoption = TrainingJobAdoption.new(job, program)

    assert {:ok,
            %TrainingResult{
              status: :completed,
              job: ^job,
              program: rebound,
              metadata: %{operation: :training_job_adoption, training_performed: false}
            }} = Imp.train(program, adoption, trainset)

    refute_received {:artifact_build, _, _}
    assert {:ok, prediction} = Imp.call(rebound, %{question: "frozen probe"})
    assert Imp.Prediction.get(prediction, :answer) == "trained-behavior"
    assert model_id(Imp.ProgramAccess.lm(rebound)) == Path.expand(job.result_model)

    metadata = Imp.ProgramAccess.get_metadata(rebound, :training_artifact)
    assert metadata.job_id == job.id
    assert metadata.result_model == job.result_model
    assert metadata.artifact_sha256 == job.metadata.artifact_sha256

    job_path = Path.join(context.root, "adopted-job.json")
    program_path = Path.join(context.root, "adopted-program.json")
    fresh_path = Path.join(context.root, "adopted-fresh.json")
    :ok = TrainingJob.save!(job, job_path)
    :ok = Imp.save!(rebound, program_path)
    :ok = Imp.Clients.MLXLMDeployment.stop(job)

    script = """
    job = Imp.Clients.TrainingJob.read!(#{inspect(job_path)})
    program = Imp.read!(#{inspect(program_path)})
    {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, program)
    {:ok, prediction} = Imp.call(rebound, %{question: "frozen probe"})
    lm = Imp.ProgramAccess.lm(rebound)
    File.write!(#{inspect(fresh_path)}, Jason.encode!(%{
      answer: Imp.Prediction.get(prediction, :answer),
      model: lm.model.id,
      artifact: Imp.ProgramAccess.get_metadata(rebound, :training_artifact).artifact_sha256
    }))
    :ok = Imp.Clients.MLXLMDeployment.stop(job)
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", script],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{
             "answer" => "trained-behavior",
             "model" => model,
             "artifact" => artifact
           } = fresh_path |> File.read!() |> Jason.decode!()

    assert model == Path.expand(job.result_model)
    assert artifact == job.metadata.artifact_sha256
  end

  test "BetterTogether uses adoption as a weight step before prompt continuation", context do
    {job, program, trainset} = completed_job_fixture(context, &successful_runner/3)
    adoption = TrainingJobAdoption.new(job, program)

    optimizer =
      BetterTogether.new(fn _example, _prediction -> 1.0 end, %{
        w: adoption,
        p: %ObservePromptContinuation{owner: self()}
      })

    compiled =
      BetterTogether.compile(optimizer, program, trainset, nil,
        strategy: [:w, :p],
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received {:prompt_step_observed, "trained-behavior", fused_path, [artifact]}
    assert fused_path == Path.expand(job.result_model)
    assert artifact.job_id == job.id
    assert artifact.artifact_sha256 == job.metadata.artifact_sha256
    assert Imp.ProgramAccess.lm(compiled).model.id == fused_path

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Keep using the verified trained model."

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.selected_strategy == "w -> p"
    assert :ok = Imp.Clients.MLXLMDeployment.stop(job)
  end

  test "BetterTogether admits and scores an adopted weight prefix before prompt continuation",
       context do
    {job, fixture_program, trainset} =
      completed_job_fixture(context, &successful_runner/3)

    build_program = fn ->
      base_path = Path.expand(context.model_path)

      Imp.with_lm(
        fixture_program,
        Imp.req_llm(
          %{
            provider: :openai,
            id: base_path,
            model: base_path,
            base_url: "http://127.0.0.1:1/v1",
            extra: %{openai_compatible_backend: :mlx_lm}
          },
          req_module: DeterministicBaseLM,
          cache: false,
          temperature: 0,
          max_tokens: 32,
          max_retries: 0,
          req_http_options: [retry: false, max_retries: 0]
        )
      )
    end

    program = build_program.()

    adoption = TrainingJobAdoption.new(job, program)

    assert {:ok, %TrainingResult{program: standalone_adopted}} =
             Imp.train(program, adoption, trainset)

    assert model_id(Imp.ProgramAccess.lm(standalone_adopted)) == Path.expand(job.result_model)

    # Match the real consumer shape: the adoption is bound before a standalone
    # lifecycle check, then composition receives a freshly reconstructed but
    # byte-equivalent base program.
    composition_program = build_program.()
    assert Imp.Saving.dump(composition_program) == Imp.Saving.dump(program)

    metric = fn example, prediction ->
      Imp.get(example, :answer) == Imp.get(prediction, :answer)
    end

    optimizer =
      BetterTogether.new(metric, %{
        w: adoption,
        p: %ObservePromptContinuation{owner: self()}
      })

    compiled =
      BetterTogether.compile(optimizer, composition_program, trainset, trainset,
        strategy: [:w, :p],
        valset_ratio: 0,
        shuffle_trainset_between_steps: false,
        num_threads: 1
      )

    report = Imp.Optimizer.Report.fetch(compiled)
    report_path = Path.join(context.root, "composition-return.json")
    temporary_report_path = report_path <> ".tmp"

    File.write!(
      temporary_report_path,
      Jason.encode!(Imp.Optimizer.Report.dump(report)),
      [:sync]
    )

    File.rename!(temporary_report_path, report_path)

    assert_received {:prompt_step_observed, "trained-behavior", fused_path, [_artifact]}
    assert fused_path == Path.expand(job.result_model)

    persisted_report =
      report_path |> File.read!() |> Jason.decode!() |> Imp.Optimizer.Report.load!()

    assert persisted_report.metadata.selected_strategy in ["w", "w -> p"]

    assert Enum.map(report.candidates, &{&1.strategy, &1.status, &1.score}) == [
             {"", :ok, 0.0},
             {"w", :ok, 1.0},
             {"w -> p", :ok, 1.0}
           ]

    assert report.metadata.selected_strategy in ["w", "w -> p"]
    refute report.metadata.compilation_error_occurred
    assert :ok = Imp.Clients.MLXLMDeployment.stop(job)
  end

  test "adoption fails closed on job, artifact, base-program, and program drift", context do
    {job, program, trainset} = completed_job_fixture(context, &successful_runner/3)
    adoption = TrainingJobAdoption.new(job, program)

    changed_job = %{job | model: "different/base"}

    assert {:error, {:training_job_adoption_failed, :adoption_job_identity_mismatch}} =
             Imp.train(program, %{adoption | job: changed_job}, trainset)

    changed_program =
      Imp.Optimizer.InstructionSearch.put_instruction(program, "A different task instruction.")

    assert {:error, {:training_job_adoption_failed, :adoption_program_identity_mismatch}} =
             Imp.train(changed_program, adoption, trainset)

    wrong_base =
      Imp.predict(Imp.ProgramAccess.task_signature(program),
        lm: %Imp.Clients.ReqLLM{model: "/different/base", opts: []}
      )

    assert_raise ArgumentError, ~r/adoption_program_base_model_mismatch/, fn ->
      TrainingJobAdoption.new(job, wrong_base)
    end

    weights = Path.join(job.result_model, "model.safetensors")
    File.write!(weights, File.read!(weights) <> "tampered", [:sync])

    assert {:error,
            {:training_job_adoption_failed,
             {:mlx_lm_artifact_tree_mismatch, %{actual_sha256: actual, expected_sha256: expected}}}} =
             Imp.train(program, adoption, trainset)

    refute actual == expected
  end

  defp successful_runner(_executable, argv, _opts) do
    if "--train" in argv do
      adapter_dir = value_after(argv, "--adapter-path")
      model_path = value_after(argv, "--model")
      File.mkdir_p!(adapter_dir)

      File.write!(
        Path.join(adapter_dir, "adapter_config.json"),
        Jason.encode!(%{"model" => model_path, "fine_tune_type" => "lora"}),
        [:sync]
      )

      File.write!(Path.join(adapter_dir, "adapters.safetensors"), "trained-adapter", [:sync])
    else
      fused_dir = value_after(argv, "--save-path")
      File.mkdir_p!(fused_dir)
      File.write!(Path.join(fused_dir, "config.json"), "{}", [:sync])
      File.write!(Path.join(fused_dir, "model.safetensors"), "trained-model", [:sync])
      File.write!(Path.join(fused_dir, "behavior.txt"), "trained-behavior\n", [:sync])
    end

    {:ok, %{exit_status: 0, output: "ok", duration_ms: 1}}
  end

  defp completed_job_fixture(context, runner) do
    port = available_port()
    signature = Imp.signature("question -> answer")

    trainer =
      MLXLMTrainer.new(
        root: Path.join(context.root, "adoption-runs"),
        model_path: context.model_path,
        model_revision: @revision,
        signature: signature,
        runner: runner,
        validation_fraction: 0,
        iters: 1,
        save_every: 1,
        server_executable: System.find_executable("python3"),
        server_executable_args: [Path.expand("support/fake_mlx_server.py", __DIR__)],
        server_port: port,
        server_startup_timeout: 5_000
      )

    trainset = [
      Imp.example(question: "frozen probe", answer: "trained-behavior")
      |> Imp.with_inputs([:question])
    ]

    assert {:ok, %TrainingJob{status: :succeeded} = job} =
             Trainer.finetune(trainer, %{deployment: :not_used}, trainset)

    program =
      Imp.predict(signature,
        lm: %Imp.Clients.ReqLLM{model: Path.expand(context.model_path), opts: []}
      )

    {job, program, trainset}
  end

  defp value_after(argv, flag), do: Enum.at(argv, Enum.find_index(argv, &(&1 == flag)) + 1)

  defp model_id(%Imp.Clients.ReqLLM{model: model}),
    do: Map.get(model, :id) || Map.get(model, "id")

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
