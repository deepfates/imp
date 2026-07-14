defmodule Imp.Clients.MLXLMTrainerTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.{MLXLMTrainer, Trainer, TrainingJob}
  alias Imp.Training.ChatDataset

  @revision "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"

  setup do
    root = Path.join(System.tmp_dir!(), "imp-mlx-test-#{System.unique_integer([:positive])}")
    model_path = Path.join([root, "model", @revision])
    File.mkdir_p!(model_path)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, model_path: model_path}
  end

  test "defaults reproduce the proven MLX-LM 0.31.3 training profile", context do
    trainer =
      MLXLMTrainer.new(
        root: Path.join(context.root, "runs"),
        model_path: context.model_path,
        signature: Imp.signature("question -> answer")
      )

    assert MLXLMTrainer.mlx_lm_version() == "0.31.3"

    assert MLXLMTrainer.default_model() ==
             {"mlx-community/Qwen2.5-0.5B-Instruct-4bit", @revision}

    assert %{
             validation_fraction: 0.1,
             stratify_by: [],
             seed: 0,
             iters: 216,
             batch_size: 1,
             grad_accumulation_steps: 4,
             learning_rate: 1.0e-4,
             num_layers: 8,
             max_seq_length: 512,
             mask_prompt: true
           } = trainer

    assert {:error, {:invalid_mlx_lm_options, message}} =
             train(trainer, grad_accumulation_steps: 0)

    assert message =~ "grad_accumulation_steps must be positive"
  end

  test "actual adapter JSONL and stratified split hashes are deterministic" do
    signature = Imp.signature("question -> answer", "Answer exactly.")

    examples = [
      example("q1", "a1", "easy"),
      example("q2", "a2", "easy"),
      example("q3", "a3", "hard"),
      example("q4", "a4", "hard")
    ]

    opts = [validation_fraction: 0.5, stratify_by: :difficulty, seed: 17]
    assert {:ok, first} = ChatDataset.build(examples, signature, Imp.Adapter.Chat, opts)

    assert {:ok, second} =
             ChatDataset.build(Enum.reverse(examples), signature, Imp.Adapter.Chat, opts)

    assert first == second
    assert first.train_count == 2
    assert first.valid_count == 2
    assert first.dataset_sha256 =~ ~r/^[0-9a-f]{64}$/

    rows = decode_jsonl(first.train_jsonl <> first.valid_jsonl)
    assert length(rows) == 4

    assert Enum.all?(rows, fn %{"messages" => messages} ->
             last = List.last(messages)

             last["role"] == "assistant" and last["content"] != "" and
               last["content"] =~ "[[ ## answer ## ]]"
           end)

    refute Enum.any?(rows, fn %{"messages" => messages} ->
             match?(%{"role" => "user", "content" => ""}, List.last(messages))
           end)

    valid_answers =
      first.valid_jsonl
      |> decode_jsonl()
      |> Enum.map(&List.last(&1["messages"])["content"])

    assert Enum.count(valid_answers, &(&1 =~ "a1" or &1 =~ "a2")) == 1
    assert Enum.count(valid_answers, &(&1 =~ "a3" or &1 =~ "a4")) == 1
  end

  test "uses executable plus argv, succeeds only with hashed artifacts, and replays idempotently",
       context do
    parent = self()

    runner = fn executable, argv, opts ->
      send(parent, {:run, executable, argv, opts})
      write_adapter!(argv)
      {:ok, %{exit_status: 0, output: "trained", duration_ms: 12}}
    end

    trainer = trainer(context, runner)
    assert {:ok, %TrainingJob{status: :succeeded} = first} = train(trainer)
    assert_received {:run, "mlx_lm.lora", argv, opts}
    assert "--train" in argv
    assert Enum.at(argv, index_of(argv, "--model") + 1) == context.model_path
    assert Enum.at(argv, index_of(argv, "--data") + 1) |> Path.basename() == "data"
    assert Enum.at(argv, index_of(argv, "--grad-accumulation-steps") + 1) == "4"
    assert opts[:cd] |> Path.type() == :absolute
    refute Enum.any?(argv, &String.contains?(&1, ";"))

    manifest = read_manifest(Path.expand(first.metadata.manifest, first.result_model))
    assert manifest["status"] == "succeeded"
    assert get_in(manifest, ["artifacts", "adapters.safetensors", "sha256"]) =~ ~r/^[0-9a-f]{64}$/
    assert {:ok, ^manifest} = MLXLMTrainer.verify_job(first)

    checkpoint = Path.join(context.root, "job.json")
    TrainingJob.save!(first, checkpoint)
    assert {:ok, ^manifest} = checkpoint |> TrainingJob.load!() |> MLXLMTrainer.verify_job()

    assert {:ok, %TrainingJob{id: id, result_model: result_model}} = train(trainer)
    assert id == first.id
    assert result_model == first.result_model
    refute_received {:run, _, _, _}
  end

  test "supports a pinned launcher prefix without invoking a shell", context do
    parent = self()

    runner = fn executable, argv, _opts ->
      send(parent, {:run, executable, argv})
      write_adapter!(argv)
      {:ok, %{exit_status: 0}}
    end

    trainer =
      context
      |> trainer(runner)
      |> Map.merge(%{
        executable: "uvx",
        executable_args: ["--from", "mlx-lm==0.31.3", "mlx_lm.lora"]
      })

    assert {:ok, %TrainingJob{status: :succeeded}} = train(trainer)

    assert_received {:run, "uvx", ["--from", "mlx-lm==0.31.3", "mlx_lm.lora", "--model" | _rest]}
  end

  test "rejects missing artifacts, nonzero exits, timeout secrets, and completed-run tampering",
       context do
    missing =
      trainer(context, fn _exe, _argv, _opts -> {:ok, %{exit_status: 0, output: "ok"}} end)

    assert {:error, {:mlx_lm_command_failed, :mlx_lm_adapter_artifact_missing_or_invalid}} =
             train(missing)

    File.rm_rf!(Path.join(context.root, "runs"))

    nonzero =
      trainer(context, fn _exe, _argv, _opts ->
        {:error, {:exit_status, 9, %{exit_status: 9, output: "bad"}}}
      end)

    assert {:error, {:mlx_lm_command_failed, {:exit_status, 9, _result}}} = train(nonzero)

    File.rm_rf!(Path.join(context.root, "runs"))
    secret = "sk-timeout-secret-1234567890"

    timed_out =
      trainer(context, fn _exe, _argv, _opts -> {:error, {:timeout, %{output: secret}}} end)

    assert {:error, {:mlx_lm_command_failed, {:timeout, %{output: "[REDACTED]"}}}} =
             train(timed_out)

    File.rm_rf!(Path.join(context.root, "runs"))

    good =
      trainer(context, fn _exe, argv, _opts ->
        write_adapter!(argv)
        {:ok, %{exit_status: 0}}
      end)

    assert {:ok, job} = train(good)
    File.write!(Path.join(job.result_model, "adapters.safetensors"), "tampered", [:sync])
    assert {:error, :mlx_lm_adapter_artifact_tampered} = MLXLMTrainer.verify_job(job)
    assert {:error, :mlx_lm_adapter_artifact_tampered} = train(good)
  end

  test "resumes only from a valid hashed MLX adapter checkpoint", context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    runner = fn _executable, argv, _opts ->
      attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(parent, {:attempt, attempt, argv})
      write_adapter!(argv)

      if attempt == 0,
        do: {:error, {:exit_status, 2, %{exit_status: 2, output: "interrupted"}}},
        else: {:ok, %{exit_status: 0, output: "resumed"}}
    end

    trainer = trainer(context, runner)
    assert {:error, {:mlx_lm_command_failed, {:exit_status, 2, _}}} = train(trainer)
    assert_received {:attempt, 0, first_argv}
    refute "--resume-adapter-file" in first_argv

    assert {:ok, %TrainingJob{status: :succeeded}} = train(trainer)
    assert_received {:attempt, 1, resumed_argv}
    resume_index = index_of(resumed_argv, "--resume-adapter-file")

    assert Enum.at(resumed_argv, resume_index + 1)
           |> String.ends_with?("adapter/adapters.safetensors")
  end

  defp trainer(context, runner) do
    MLXLMTrainer.new(
      root: Path.join(context.root, "runs"),
      model_path: context.model_path,
      model_revision: @revision,
      signature: Imp.signature("question -> answer"),
      runner: runner,
      validation_fraction: 0.5,
      iters: 2,
      save_every: 1
    )
  end

  defp train(trainer),
    do: train(trainer, [])

  defp train(trainer, opts),
    do:
      Trainer.finetune(
        trainer,
        %{deployment: :not_used},
        [
          example("2+2?", "4", "math"),
          example("3+3?", "6", "math")
        ],
        opts
      )

  defp example(question, answer, difficulty) do
    Imp.example(question: question, answer: answer, difficulty: difficulty)
    |> Imp.with_inputs([:question])
  end

  defp write_adapter!(argv) do
    adapter_dir = Enum.at(argv, index_of(argv, "--adapter-path") + 1)
    model_path = Enum.at(argv, index_of(argv, "--model") + 1)
    File.mkdir_p!(adapter_dir)

    File.write!(
      Path.join(adapter_dir, "adapter_config.json"),
      Jason.encode!(%{"model" => model_path, "fine_tune_type" => "lora"}),
      [:sync]
    )

    File.write!(Path.join(adapter_dir, "adapters.safetensors"), "valid-adapter-weights", [:sync])
    :ok
  end

  defp index_of(argv, flag), do: Enum.find_index(argv, &(&1 == flag))

  defp read_manifest(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("payload")

  defp decode_jsonl(jsonl) do
    jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
