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
      write_mlx_artifact!(argv)
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
    assert_received {:run, "mlx_lm.fuse", fusion_argv, _opts}

    fusion_output = Enum.at(fusion_argv, index_of(fusion_argv, "--save-path") + 1)
    assert {:ok, first.result_model} == Imp.Clients.MLXLMArtifact.canonical_path(fusion_output)

    manifest = read_manifest(Path.expand(first.metadata.manifest, first.result_model))
    assert manifest["status"] == "succeeded"
    assert get_in(manifest, ["artifacts", "adapters.safetensors", "sha256"]) =~ ~r/^[0-9a-f]{64}$/
    assert get_in(manifest, ["fused_tree", "sha256"]) =~ ~r/^[0-9a-f]{64}$/
    assert Path.basename(first.result_model) == "fused"
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
      write_mlx_artifact!(argv)
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

    assert_received {:run, "uvx", ["--from", "mlx-lm==0.31.3", "mlx_lm.fuse", "--model" | _rest]}
  end

  test "rejects missing artifacts, nonzero exits, timeout secrets, and completed-run tampering",
       context do
    missing_manifest =
      TrainingJob.new(%{
        provider: :mlx_lm,
        status: :succeeded,
        result_model: context.model_path
      })

    assert {:error, :mlx_lm_job_manifest_path_missing} =
             MLXLMTrainer.verify_job(missing_manifest)

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
        write_mlx_artifact!(argv)
        {:ok, %{exit_status: 0}}
      end)

    assert {:ok, job} = train(good)
    File.write!(Path.join(job.result_model, "model.safetensors"), "tampered", [:sync])
    assert {:error, {:mlx_lm_artifact_tree_mismatch, _}} = MLXLMTrainer.verify_job(job)
    assert {:error, {:mlx_lm_artifact_tree_mismatch, _}} = train(good)
  end

  test "resumes only from a valid hashed MLX adapter checkpoint", context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    runner = fn _executable, argv, _opts ->
      if "--train" in argv do
        attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(parent, {:attempt, attempt, argv})
        write_adapter!(argv)

        if attempt == 0,
          do: {:error, {:exit_status, 2, %{exit_status: 2, output: "interrupted"}}},
          else: {:ok, %{exit_status: 0, output: "resumed"}}
      else
        write_fused!(argv)
        {:ok, %{exit_status: 0, output: "fused"}}
      end
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

  test "resumes a failed fusion without rerunning training and refuses adapter tampering",
       context do
    {:ok, counts} = Agent.start_link(fn -> %{train: 0, fuse: 0} end)

    runner = fn _executable, argv, _opts ->
      if "--train" in argv do
        Agent.update(counts, &Map.update!(&1, :train, fn value -> value + 1 end))
        write_adapter!(argv)
        {:ok, %{exit_status: 0, output: "trained"}}
      else
        attempt =
          Agent.get_and_update(counts, &{&1.fuse, Map.update!(&1, :fuse, fn v -> v + 1 end)})

        if attempt == 0 do
          {:error, {:exit_status, 7, %{exit_status: 7, output: "fusion interrupted"}}}
        else
          write_fused!(argv)
          {:ok, %{exit_status: 0, output: "fused"}}
        end
      end
    end

    trainer = trainer(context, runner)

    assert {:error, {:mlx_lm_fusion_failed, {:exit_status, 7, _capture}}} = train(trainer)
    assert Agent.get(counts, & &1) == %{train: 1, fuse: 1}

    assert {:ok, job} = train(trainer)
    assert Agent.get(counts, & &1) == %{train: 1, fuse: 2}

    assert {:ok, replayed} = train(trainer)
    assert replayed.result_model == job.result_model
    assert Agent.get(counts, & &1) == %{train: 1, fuse: 2}

    Agent.update(counts, &Map.put(&1, :fuse, 0))

    tamper_context = %{
      context
      | root: Path.join(context.root, "tamper"),
        model_path: Path.join([context.root, "tamper", "model", @revision])
    }

    File.mkdir_p!(tamper_context.model_path)
    tamper_trainer = trainer(tamper_context, runner)

    assert {:error, {:mlx_lm_fusion_failed, {:exit_status, 7, _capture}}} =
             train(tamper_trainer)

    run_dir =
      tamper_trainer.root
      |> File.ls!()
      |> List.first()
      |> then(&Path.join(tamper_trainer.root, &1))

    File.write!(Path.join([run_dir, "adapter", "adapters.safetensors"]), "tampered", [:sync])
    before_retry = Agent.get(counts, & &1)

    assert {:error, {:mlx_lm_fusion_failed, :mlx_lm_adapter_artifact_tampered}} =
             train(tamper_trainer)

    assert Agent.get(counts, & &1) == before_retry
  end

  test "does not admit a fused tree that is byte-identical to the pinned base", context do
    File.write!(Path.join(context.model_path, "config.json"), Jason.encode!(%{"fused" => true}), [
      :sync
    ])

    File.write!(Path.join(context.model_path, "model.safetensors"), "fused-trained-weights", [
      :sync
    ])

    File.write!(Path.join(context.model_path, "behavior.txt"), "trained-behavior\n", [:sync])

    assert {:error,
            {:mlx_lm_fusion_failed, :mlx_lm_fused_artifact_missing_invalid_or_base_identical}} =
             context |> trainer(&successful_runner/3) |> train()
  end

  test "deploys the exact fused tree, persists it, and runs it from a fresh process", context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()
    server = Path.expand("support/fake_mlx_server.py", __DIR__)

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [server],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)
    assert File.read!(Path.join(job.result_model, "behavior.txt")) == "trained-behavior\n"

    program =
      Imp.predict("question -> answer",
        lm: Imp.req_llm(Path.expand(context.model_path), api_key: "local")
      )

    program_path = Path.join(context.root, "trained-program.json")
    job_path = Path.join(context.root, "training-job.json")

    assert {:ok, rebound} = TrainingJob.rebind(job, program, path: program_path)
    assert {:ok, prediction} = Imp.call(rebound, %{question: "frozen probe"})
    assert Imp.Prediction.get(prediction, :answer) == "trained-behavior"

    lm = Imp.ProgramAccess.lm(rebound)
    assert lm.model.id == Path.expand(job.result_model)
    assert lm.model.model == Path.expand(job.result_model)

    assert Imp.ProgramAccess.get_metadata(rebound, :training_artifact).artifact_sha256 ==
             job.metadata.artifact_sha256

    :ok = TrainingJob.save!(job, job_path)
    assert :ok = Imp.Clients.MLXLMDeployment.stop(job)

    fresh_result = Path.join(context.root, "fresh-result.json")

    code = """
    job = Imp.Clients.TrainingJob.load!(#{inspect(job_path)})
    loaded = Imp.load!(#{inspect(program_path)})
    {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, loaded)
    {:ok, prediction} = Imp.call(rebound, %{question: "frozen probe"})
    lm = Imp.ProgramAccess.lm(rebound)
    payload = %{
      answer: Imp.Prediction.get(prediction, :answer),
      artifact_path: job.result_model,
      artifact_sha256: job.metadata["artifact_sha256"],
      served_model: lm.model.id
    }
    File.write!(#{inspect(fresh_result)}, Jason.encode!(payload))
    :ok = Imp.Clients.MLXLMDeployment.stop(job)
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert %{
             "answer" => "trained-behavior",
             "artifact_path" => artifact_path,
             "artifact_sha256" => artifact_sha256,
             "served_model" => served_model
           } = Jason.decode!(File.read!(fresh_result))

    assert artifact_path == Path.expand(job.result_model)
    assert served_model == artifact_path
    assert artifact_sha256 == job.metadata.artifact_sha256
  end

  test "rebind preserves explicit runtime safety options across a fresh counting lifecycle",
       context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()
    request_log = Path.join(context.root, "requests.jsonl")
    server = Path.expand("support/fake_mlx_server.py", __DIR__)

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [server, "--record-requests", request_log],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)
    base_path = Path.expand(context.model_path)

    source_lm =
      Imp.req_llm(
        %{
          provider: :openai,
          id: base_path,
          model: base_path,
          base_url: "http://127.0.0.1:1/v1",
          extra: %{openai_compatible_backend: :mlx_lm}
        },
        api_key: "local",
        cache: false,
        temperature: 0.25,
        seed: 17,
        max_tokens: 32,
        max_retries: 0,
        timeout: 10_000,
        req_http_options: [retry: false, max_retries: 0]
      )

    source =
      Imp.predict("question -> answer",
        lm: source_lm,
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    assert {:ok, rebound} = TrainingJob.rebind(job, source)
    rebound_lm = Imp.ProgramAccess.lm(rebound)
    assert rebound.adapter == Imp.Adapter.Chat
    assert rebound.config == [json_fallback: false]
    assert rebound_lm.model.id == Path.expand(job.result_model)
    assert rebound_lm.model.provider == :openai
    assert rebound_lm.opts[:cache] == false
    assert rebound_lm.opts[:temperature] == 0.25
    assert rebound_lm.opts[:seed] == 17
    assert rebound_lm.opts[:max_tokens] == 32
    assert rebound_lm.opts[:max_retries] == 0
    assert rebound_lm.opts[:req_http_options] == [retry: false, max_retries: 0]

    assert {:ok, first} = Imp.call(rebound, %{question: "same frozen probe"})
    assert {:ok, second} = Imp.call(rebound, %{question: "same frozen probe"})
    assert Imp.Prediction.get(first, :answer) == "trained-behavior"
    assert Imp.Prediction.get(second, :answer) == "trained-behavior"
    assert request_count(request_log) == 2

    differently_tuned =
      Imp.with_lm(source, %{source_lm | opts: Keyword.put(source_lm.opts, :temperature, 0.75)})

    assert {:ok, second_rebound} = TrainingJob.rebind(job, differently_tuned)
    assert Imp.ProgramAccess.lm(second_rebound).opts[:temperature] == 0.75
    assert Imp.ProgramAccess.lm(rebound).opts[:temperature] == 0.25

    job_path = Path.join(context.root, "counting-job.json")
    program_path = Path.join(context.root, "counting-program.json")
    fresh_path = Path.join(context.root, "counting-fresh.json")
    :ok = TrainingJob.save!(job, job_path)
    :ok = Imp.save!(rebound, program_path)
    assert :ok = Imp.Clients.MLXLMDeployment.stop(job)

    code = """
    job = Imp.Clients.TrainingJob.load!(#{inspect(job_path)})
    try do
      source = Imp.load!(#{inspect(program_path)})
      {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, source)
      {:ok, first} = Imp.call(rebound, %{question: "same frozen probe"})
      {:ok, second} = Imp.call(rebound, %{question: "same frozen probe"})
      lm = Imp.ProgramAccess.lm(rebound)
      opts = %{
        cache: lm.opts[:cache],
        seed: lm.opts[:seed],
        max_retries: lm.opts[:max_retries],
        req_http_options: Map.new(lm.opts[:req_http_options])
      }
      File.write!(#{inspect(fresh_path)}, Jason.encode!(%{
        answers: [Imp.Prediction.get(first, :answer), Imp.Prediction.get(second, :answer)],
        model: lm.model.id,
        opts: opts,
        adapter: rebound.adapter,
        config: Map.new(rebound.config)
      }))
    after
      :ok = Imp.Clients.MLXLMDeployment.stop(job)
    end
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert request_count(request_log) == 4

    request_digests =
      request_log
      |> File.read!()
      |> decode_jsonl()
      |> Enum.map(& &1["canonical_body_sha256"])

    assert length(Enum.uniq(request_digests)) == 1

    fresh = Jason.decode!(File.read!(fresh_path))
    assert fresh["answers"] == ["trained-behavior", "trained-behavior"]
    assert fresh["model"] == Path.expand(job.result_model)
    assert fresh["adapter"] == "Elixir.Imp.Adapter.Chat"
    assert fresh["config"] == %{"json_fallback" => false}
    assert fresh["opts"]["cache"] == false
    assert fresh["opts"]["seed"] == 17
    assert fresh["opts"]["max_retries"] == 0
    assert fresh["opts"]["req_http_options"] == %{"retry" => false, "max_retries" => 0}

    assert_port_available!(port)
  end

  test "rebind refuses MLX provider, model, credential, and option conflicts before launch",
       context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [Path.expand("support/fake_mlx_server.py", __DIR__)],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)
    base_path = Path.expand(context.model_path)

    program_for = fn model, opts ->
      Imp.predict("question -> answer", lm: Imp.req_llm(model, opts))
    end

    conflicting_provider =
      %{provider: :anthropic, id: base_path, model: base_path, base_url: "http://invalid"}

    assert {:error, {:mlx_lm_rebind_provider_conflict, ^conflicting_provider}} =
             TrainingJob.rebind(job, program_for.(conflicting_provider, []))

    wrong_model = Path.join(context.root, "different-model")

    assert {:error, {:mlx_lm_rebind_source_model_mismatch, _allowed, ^wrong_model}} =
             TrainingJob.rebind(job, program_for.(wrong_model, []))

    assert {:error, :mlx_lm_rebind_credential_conflict} =
             TrainingJob.rebind(job, program_for.(base_path, api_key: "external-secret"))

    assert {:error, {:mlx_lm_rebind_unsupported_options, [:base_url]}} =
             TrainingJob.rebind(job, program_for.(base_path, base_url: "http://invalid"))

    assert {:error, {:mlx_lm_rebind_invalid_option, :seed, 0}} =
             TrainingJob.rebind(job, program_for.(base_path, seed: 0))

    malformed_options = %{Imp.req_llm(base_path) | opts: [:not_a_pair]}

    assert {:error, :mlx_lm_rebind_options_must_be_keyword_list} =
             TrainingJob.rebind(job, Imp.predict("question -> answer", lm: malformed_options))

    duplicate_options = %{Imp.req_llm(base_path) | opts: [cache: false, cache: true]}

    assert {:error, :mlx_lm_rebind_duplicate_options} =
             TrainingJob.rebind(job, Imp.predict("question -> answer", lm: duplicate_options))

    assert {:error, :mlx_lm_rebind_req_http_options_must_be_keyword_list} =
             TrainingJob.rebind(job, program_for.(base_path, req_http_options: [:not_a_pair]))

    assert {:error, {:mlx_lm_rebind_unsupported_req_http_options, [:plugins]}} =
             TrainingJob.rebind(
               job,
               program_for.(base_path, req_http_options: [plugins: [:unexpected]])
             )

    assert :error = Imp.Clients.MLXLMDeployment.lookup(job)
    assert_port_available!(port)
  end

  test "fresh-process consumer cleanup survives a downstream recorder failure", context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [Path.expand("support/fake_mlx_server.py", __DIR__)],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)
    base_path = Path.expand(context.model_path)

    program =
      Imp.predict("question -> answer",
        lm:
          Imp.req_llm(base_path,
            api_key: "local",
            cache: false,
            max_retries: 0,
            req_http_options: [retry: false, max_retries: 0]
          ),
        config: [json_fallback: false]
      )

    job_path = Path.join(context.root, "failure-cleanup-job.json")
    program_path = Path.join(context.root, "failure-cleanup-program.json")
    :ok = TrainingJob.save!(job, job_path)
    :ok = Imp.save!(program, program_path)

    code = """
    job = Imp.Clients.TrainingJob.load!(#{inspect(job_path)})
    try do
      program = Imp.load!(#{inspect(program_path)})
      {:ok, rebound} = Imp.Clients.TrainingJob.rebind(job, program)
      {:ok, _prediction} = Imp.call(rebound, %{question: "cleanup probe"})
      raise "forced recorder failure"
    after
      :ok = Imp.Clients.MLXLMDeployment.stop(job)
    end
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "forced recorder failure"
    assert_port_available!(port)
  end

  test "deployment rejects a server that advertises any other model and cleans it up", context do
    port = available_port()
    cache_record = Path.join(context.root, "rejected-deployment-cache-root.txt")

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [
          Path.expand("support/fake_mlx_server.py", __DIR__),
          "--advertise-model",
          "/wrong/base-model",
          "--record-cache-root",
          cache_record
        ],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)

    assert {:error,
            {:mlx_lm_deployment_start_failed,
             {:mlx_lm_server_model_identity_mismatch, expected, ["/wrong/base-model"]}}} =
             Imp.Clients.MLXLMDeployment.start(job)

    assert expected == job.result_model
    refute File.exists?(File.read!(cache_record))
    assert_port_available!(port)
  end

  test "deployment isolates a poisoned ambient model cache and removes its owned cache",
       context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()
    poisoned = Path.join(context.root, "poisoned-huggingface")
    cache_record = Path.join(context.root, "deployment-cache-root.txt")
    env_record = Path.join(context.root, "deployment-cache-env.json")
    uv_cache = Path.join(context.root, "verified-uv-cache")
    xdg_cache = Path.join(context.root, "ambient-xdg-cache")
    File.mkdir_p!(poisoned)
    File.mkdir_p!(uv_cache)
    File.mkdir_p!(xdg_cache)
    File.write!(Path.join(poisoned, "poisoned-model-id"), "jxm/gpt-oss-20b-base\n", [:sync])

    previous_hf_home = System.get_env("HF_HOME")
    previous_uv_cache = System.get_env("UV_CACHE_DIR")
    previous_xdg_cache = System.get_env("XDG_CACHE_HOME")
    System.put_env("HF_HOME", poisoned)
    System.put_env("UV_CACHE_DIR", uv_cache)
    System.put_env("XDG_CACHE_HOME", xdg_cache)

    on_exit(fn ->
      if previous_hf_home,
        do: System.put_env("HF_HOME", previous_hf_home),
        else: System.delete_env("HF_HOME")

      if previous_uv_cache,
        do: System.put_env("UV_CACHE_DIR", previous_uv_cache),
        else: System.delete_env("UV_CACHE_DIR")

      if previous_xdg_cache,
        do: System.put_env("XDG_CACHE_HOME", previous_xdg_cache),
        else: System.delete_env("XDG_CACHE_HOME")
    end)

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [
          Path.expand("support/fake_mlx_server.py", __DIR__),
          "--advertise-ambient-cache-model",
          "jxm/gpt-oss-20b-base",
          "--record-cache-root",
          cache_record,
          "--record-cache-env",
          env_record
        ],
        server_port: port,
        server_startup_timeout: 5_000
      })

    assert {:ok, job} = train(trainer)
    assert {:ok, deployment} = Imp.Clients.MLXLMDeployment.start(job)

    isolated_cache = File.read!(cache_record)
    refute isolated_cache == poisoned
    assert File.dir?(isolated_cache)
    refute File.exists?(Path.join(isolated_cache, "poisoned-model-id"))

    cache_env = Jason.decode!(File.read!(env_record))
    assert cache_env["HF_HOME"] == isolated_cache
    assert cache_env["HUGGINGFACE_HUB_CACHE"] == Path.join(isolated_cache, "hub")
    assert File.dir?(cache_env["HUGGINGFACE_HUB_CACHE"])
    assert cache_env["TRANSFORMERS_CACHE"] != poisoned
    assert cache_env["HF_DATASETS_CACHE"] != poisoned
    assert cache_env["UV_CACHE_DIR"] == uv_cache
    assert cache_env["XDG_CACHE_HOME"] == xdg_cache

    assert {:ok, %{body: %{"data" => [%{"id" => advertised}]}}} =
             Req.get(deployment.base_url <> "/models", retry: false)

    assert advertised == Path.expand(job.result_model)
    assert File.exists?(Path.join(poisoned, "poisoned-model-id"))

    assert :ok = Imp.Clients.MLXLMDeployment.stop(job)
    refute File.exists?(isolated_cache)
    assert_port_available!(port)
  end

  test "deployment readiness timeout retains bounded server output and cleans up", context do
    File.write!(Path.join(context.model_path, "behavior.txt"), "base-behavior\n", [:sync])
    port = available_port()
    cache_record = Path.join(context.root, "timeout-deployment-cache-root.txt")

    trainer =
      context
      |> trainer(&successful_runner/3)
      |> Map.merge(%{
        server_executable: System.find_executable("python3"),
        server_executable_args: [
          Path.expand("support/fake_mlx_server.py", __DIR__),
          "--never-ready",
          "--record-cache-root",
          cache_record
        ],
        server_port: port,
        server_startup_timeout: 100,
        max_output_bytes: 128
      })

    assert {:ok, job} = train(trainer)

    assert {:error,
            {:mlx_lm_deployment_start_failed,
             {:mlx_lm_server_readiness_timeout, %{artifact_path: artifact_path, process: process}}}} =
             Imp.Clients.MLXLMDeployment.start(job)

    assert artifact_path == Path.expand(job.result_model)
    assert process.exit_status == :stopped
    assert process.output =~ "intentionally withheld readiness"
    assert byte_size(process.output) <= 128
    refute File.exists?(File.read!(cache_record))
    assert_port_available!(port)
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

  defp write_mlx_artifact!(argv) do
    if "--train" in argv, do: write_adapter!(argv), else: write_fused!(argv)
  end

  defp write_fused!(argv) do
    fused_dir = Enum.at(argv, index_of(argv, "--save-path") + 1)
    File.mkdir_p!(fused_dir)
    File.write!(Path.join(fused_dir, "config.json"), Jason.encode!(%{"fused" => true}), [:sync])
    File.write!(Path.join(fused_dir, "model.safetensors"), "fused-trained-weights", [:sync])
    File.write!(Path.join(fused_dir, "behavior.txt"), "trained-behavior\n", [:sync])
    :ok
  end

  defp successful_runner(_executable, argv, _opts) do
    write_mlx_artifact!(argv)
    {:ok, %{exit_status: 0, output: "ok", duration_ms: 1}}
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp assert_port_available!(port) do
    {:ok, socket} =
      :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    :ok = :gen_tcp.close(socket)
  end

  defp request_count(path) do
    if File.exists?(path),
      do: path |> File.read!() |> String.split("\n", trim: true) |> length(),
      else: 0
  end

  defp index_of(argv, flag), do: Enum.find_index(argv, &(&1 == flag))

  defp read_manifest(path), do: path |> File.read!() |> Jason.decode!() |> Map.fetch!("payload")

  defp decode_jsonl(jsonl) do
    jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
