defmodule Imp.Clients.MLXLMBetterTogetherTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.MLXLMTrainer
  alias Imp.Optimizer.{BetterTogether, BootstrapFinetune}

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
        Imp.ProgramAccess.get_metadata(program, :training_artifacts)
      })

      {:ok,
       Imp.Optimizer.InstructionSearch.put_instruction(
         program,
         "Keep using the verified trained model."
       )}
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
            max_concurrency: 1
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
    loaded = Imp.load!(saved_path)
    assert model_id(Imp.ProgramAccess.lm(loaded)) == fused_path

    stop_job = %Imp.Clients.TrainingJob{result_model: fused_path}
    assert :ok = Imp.Clients.MLXLMDeployment.stop(stop_job)

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.selected_strategy == "w -> p"
    refute report.metadata.compilation_error_occurred
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
