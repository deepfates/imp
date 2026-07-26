defmodule Imp.TRLWorkerTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.{TRLLM, TRLProtocol, TRLTrainer, TRLWorker}

  defmodule CompletionWorker do
    use GenServer

    def start_link({key, completion}) do
      GenServer.start_link(__MODULE__, {key, completion})
    end

    @impl true
    def init({key, completion}) do
      {:ok, _} = Registry.register(Imp.Clients.TRLWorker.Registry, key, nil)
      {:ok, completion}
    end

    @impl true
    def handle_call({:request, _request}, _from, completion) do
      result = if is_map(completion), do: completion, else: %{"completion" => completion}
      {:reply, {:ok, result}, completion}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "imp-trl-worker-#{System.unique_integer([:positive])}")
    model = Path.join(root, "missing-model")
    session_id = "trl-worker-test-#{System.unique_integer([:positive])}"
    python = System.find_executable("python3.12") || flunk("python3.12 is required")
    script = Path.expand("../priv/trl_worker/worker.py", __DIR__)
    contract = Path.expand("../priv/trl_worker/feasibility-contract.json", __DIR__)

    {:ok, worker} =
      TRLWorker.start(%{
        session_id: session_id,
        python: python,
        worker_script: script,
        root: root,
        model_path: model,
        contract_path: contract
      })

    on_exit(fn ->
      if Process.alive?(worker), do: TRLWorker.stop(worker)
      File.rm_rf!(root)
    end)

    %{worker: worker, root: root, python: python, model: model, contract: contract}
  end

  test "framed worker canonicalization matches the Elixir protocol", %{worker: worker} do
    value = %{"z" => [%{"b" => 2, "a" => 1}], "a" => true}

    assert {:ok, result} =
             TRLWorker.request(worker, %{"op" => "protocol_self_test", "value" => value}, 5_000)

    assert result["canonical"] == TRLProtocol.canonical_json(value)
    assert result["sha256"] == TRLProtocol.digest(value)
  end

  test "pinned CPython owns adversarial and retained rollout float bytes", %{worker: worker} do
    adversarial =
      [
        0.0,
        -0.0,
        1.0,
        -1.0,
        1.0e-7,
        1.0e-6,
        1.0e-5,
        1.0e15,
        1.0e16,
        1.0e20,
        1.0e21,
        1.2345678901234567,
        5.0e-324,
        2.2250738585072014e-308,
        1.7976931348623157e308,
        -5.547390460968018,
        -0.0019170732703059912,
        -4.768370445162873e-7
      ]

    value = %{"finite_floats" => adversarial ++ generated_finite_floats(2_048)}

    assert {:ok, result} =
             TRLWorker.request(worker, %{"op" => "protocol_self_test", "value" => value}, 5_000)

    assert result["canonical"] == TRLProtocol.canonical_json(value)
    assert result["sha256"] == TRLProtocol.digest(value)
    assert result["canonical"] =~ "1000000000000000.0"
    assert result["canonical"] =~ "1e-07"
    assert result["canonical"] =~ "-4.768370445162873e-07"
  end

  test "unknown operations and missing model fail without an accepted mutation", context do
    assert {:error,
            {:trl_worker,
             %{
               "accepted" => false,
               "code" => "unknown_operation",
               "message" => "operation is not allowlisted"
             }}} = TRLWorker.request(context.worker, %{"op" => "shell"}, 5_000)

    assert {:error,
            {:trl_worker,
             %{"accepted" => false, "code" => "model_missing", "message" => _message}}} =
             TRLWorker.request(context.worker, %{"op" => "initialize"}, 5_000)

    refute File.exists?(Path.join(context.root, "accepted-intent.json"))
    refute File.exists?(Path.join(context.root, "artifact"))
  end

  test "trainer constructor exposes only GRPO and preserves the fixed worker path", context do
    trainer =
      TRLTrainer.new(
        python: context.python,
        model_path: context.model,
        root: context.root,
        contract_path: context.contract
      )

    assert TRLTrainer.supported_methods(trainer) == [:grpo]

    assert trainer.worker_script ==
             :imp |> :code.priv_dir() |> to_string() |> Path.join("trl_worker/worker.py")

    assert trainer.model_path == context.model

    default =
      TRLTrainer.new(
        python: context.python,
        model_path: context.model,
        root: context.root
      )

    assert Path.basename(default.contract_path) == "qwen-one-update-contract.json"
  end

  test "the local rollout LM cannot silently create a second worker" do
    lm = %TRLLM{model: "Qwen/pinned", worker_key: {:missing, make_ref()}}
    assert {:error, :trl_worker_not_running} = Imp.LM.generate(lm, [], rollout_id: 0)
  end

  test "the controlled rollout LM remains explicit and cannot silently create a worker" do
    lm = %TRLLM{
      model: "Qwen/pinned",
      worker_key: {:missing, make_ref()},
      rollout_source: :controlled_external
    }

    assert {:error, :trl_worker_not_running} = Imp.LM.generate(lm, [], rollout_id: 0)
  end

  test "the rollout LM rejects unknown rollout sources before transport" do
    lm = %TRLLM{
      model: "Qwen/pinned",
      worker_key: {:missing, make_ref()},
      rollout_source: :not_a_rollout_source
    }

    assert {:error, {:invalid_trl_rollout_source, :not_a_rollout_source}} =
             Imp.LM.generate(lm, [], rollout_id: 0)
  end

  test "model generations remain raw for adapter parsing while controlled values stay typed" do
    completion = "[[ ## route ## ]]\nR17\n\n[[ ## completed ## ]]\n"
    key = {:trl_completion_boundary, make_ref()}
    start_supervised!({CompletionWorker, {key, completion}})

    model_lm = %TRLLM{model: "Qwen/pinned", worker_key: key}
    controlled_lm = %{model_lm | rollout_source: :controlled_external}
    trimmed = String.trim(completion)

    assert {:ok, ^completion} = Imp.LM.generate(model_lm, [%{role: "user", content: "route"}])

    assert {:ok, %{route: ^trimmed}} =
             Imp.LM.generate(controlled_lm, [%{role: "user", content: "route"}])

    signature = Imp.Signature.ensure("utterance -> route")
    assert {:ok, prediction} = Imp.Adapter.Chat.parse(signature, completion, [])
    assert Imp.get(prediction, :route) == "R17"
  end

  test "a deployed rollout refuses response artifact drift" do
    key = {:trl_deployment_identity_boundary, make_ref()}

    start_supervised!(
      {CompletionWorker,
       {key,
        %{
          "completion" => "[[ ## route ## ]]\nR17\n",
          "model" => "/tmp/different-artifact",
          "artifact_sha256" => "sha256:different"
        }}}
    )

    lm = %TRLLM{
      model: "/tmp/verified-artifact",
      worker_key: key,
      artifact_sha256: "sha256:verified"
    }

    assert {:error, {:trl_deployment_artifact_identity_mismatch, _response}} =
             Imp.LM.generate(lm, [%{role: "user", content: "route"}])
  end

  test "trainer projects atom-keyed Imp groups to the worker's plain JSON shape" do
    groups = [
      %{
        batch_id: "trl-batch-0",
        predictor: :predict,
        group_id: {0, :predict, 0},
        group: [
          %{
            messages: [%{role: "user", content: "one"}],
            completion: %{content: "R17"},
            reward: 1.0
          },
          %{
            messages: [%{role: "user", content: "one"}],
            completion: %{content: "R42"},
            reward: 0.0
          },
          %{
            messages: [%{role: "user", content: "one"}],
            completion: %{content: "R68"},
            reward: 0.0
          },
          %{
            messages: [%{role: "user", content: "one"}],
            completion: %{content: "R93"},
            reward: 0.0
          }
        ]
      }
    ]

    assert [%{"batch_id" => "trl-batch-0", "group" => samples} = group] =
             TRLTrainer.encode_groups(groups)

    assert length(samples) == 4
    assert group["predictor"] == %{"__imp_type__" => "atom", "value" => "predict"}
    assert group["group_id"]["__imp_type__"] == "tuple"
    assert Enum.map(samples, & &1["reward"]) == [1.0, 0.0, 0.0, 0.0]
  end

  defp generated_finite_floats(count) do
    0x9E3779B97F4A7C15
    |> Stream.iterate(fn bits ->
      Bitwise.band(
        bits * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407,
        0xFFFFFFFFFFFFFFFF
      )
    end)
    |> Stream.reject(fn bits -> Bitwise.band(Bitwise.bsr(bits, 52), 0x7FF) == 0x7FF end)
    |> Stream.map(fn bits ->
      <<value::float-64>> = <<bits::unsigned-64>>
      value
    end)
    |> Enum.take(count)
  end

  test "trainer atomically retains projected groups before worker validation", context do
    trainer =
      TRLTrainer.new(
        python: context.python,
        model_path: context.model,
        root: context.root,
        contract_path: context.contract
      )

    stage = %{
      "step_id" => "step-1",
      "idempotency_key" => "step-1",
      "groups" => [%{"group" => [%{"completion" => "R42", "reward" => 0.0}]}]
    }

    assert :ok = TRLTrainer.persist_prepared_stage(trainer, "session-1", stage)

    [path] = Path.wildcard(Path.join(context.root, "*/prepared-stages/*.json"))
    assert Jason.decode!(File.read!(path)) == stage
    refute File.exists?(path <> ".tmp")
  end

  test "controlled completion source has one canonical adapter rendering", context do
    script = """
    import importlib.util
    spec = importlib.util.spec_from_file_location("imp_trl_worker", #{inspect(Path.expand("../priv/trl_worker/worker.py", __DIR__))})
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    worker = object.__new__(module.Worker)
    worker.contract = {"controlled_rollouts": ["R17", "R42", "R68", "R93"]}
    groups = [{"samples": [
      {"completion": "[[ ## route ## ]]\\nR17\\n\\n[[ ## completed ## ]]\\n"},
      {"completion": "[[ ## route ## ]]\\nR42\\n\\n[[ ## completed ## ]]\\n"},
      {"completion": "[[ ## route ## ]]\\nR68\\n\\n[[ ## completed ## ]]\\n"},
      {"completion": "[[ ## route ## ]]\\nR93\\n\\n[[ ## completed ## ]]\\n"}
    ]}]
    worker._validate_controlled_groups(groups)
    """

    assert {"", 0} = System.cmd(context.python, ["-c", script], stderr_to_stdout: true)
  end

  test "ordinary one-update contracts accept arbitrary prompts and finite reward scales",
       context do
    general_contract =
      context.contract
      |> File.read!()
      |> Jason.decode!()
      |> Map.drop(["semantic_group", "controlled_rollouts"])
      |> put_in(["optimizer", "num_generations"], 2)
      |> Map.put("acceptance", %{
        "require_non_uniform_rewards" => false,
        "require_non_uniform_advantages" => false,
        "require_weight_change" => false
      })

    contract_path = Path.join(context.root, "general-contract.json")
    File.mkdir_p!(context.root)
    File.write!(contract_path, Jason.encode!(general_contract))

    script = """
    import importlib.util
    import pathlib
    spec = importlib.util.spec_from_file_location("imp_trl_worker", #{inspect(Path.expand("../priv/trl_worker/worker.py", __DIR__))})
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    class Tokenizer:
        def apply_chat_template(self, messages, tokenize=False, add_generation_prompt=True):
            return "|".join(message["content"] for message in messages)
        def __call__(self, text, add_special_tokens=False):
            return {"input_ids": [len(text), 7]}

    class NoModelWorker(module.Worker):
        def _completion_logprobs(self, prompt_ids, completion_ids):
            return [-0.5 for _ in completion_ids]

    worker = NoModelWorker(pathlib.Path(#{inspect(context.root)}) / "general", pathlib.Path(#{inspect(context.model)}), pathlib.Path(#{inspect(contract_path)}))
    worker.protocol = {
        "session_id": "general-session",
        "payload_sha256": "sha256:session",
        "optimizer": {"config_sha256": "sha256:optimizer"},
        "rng": {"algorithm": "exsss", "state_sha256": "sha256:rng"},
        "behavior_policy": {"model": "pinned-local"},
    }
    worker.model = object()
    worker.tokenizer = Tokenizer()
    group = {
        "batch_id": "batch-0",
        "group_id": [0, "router", 0],
        "predictor": "router",
        "group": [
            {"messages": [{"role": "user", "content": "public synthetic arithmetic: 2+2"}], "completion": {"content": "4"}, "reward": 0.25},
            {"messages": [{"role": "user", "content": "public synthetic arithmetic: 2+2"}], "completion": {"content": "five"}, "reward": 0.25},
        ],
    }
    prepared = worker.prepare_update({"groups": [group], "step_id": "step-0", "idempotency_key": "update-0"})
    assert [sample["reward"] for sample in prepared["groups"][0]["samples"]] == [0.25, 0.25]
    assert prepared["groups"][0]["prompt"][0]["content"].endswith("2+2")
    assert (worker.root / "prepared-controlled-group.json").is_file()
    """

    assert {"", 0} = System.cmd(context.python, ["-c", script], stderr_to_stdout: true)
  end

  test "trainer rejects rollout and step budgets before starting a worker", context do
    trainer =
      TRLTrainer.new(
        python: context.python,
        model_path: context.model,
        root: Path.join(context.root, "mismatch"),
        contract_path: context.contract,
        worker_key: {:trl_contract_mismatch, make_ref()}
      )

    protocol_contract = %{
      "dataset" => %{},
      "prompt_schedule" => %{"steps" => [%{"step" => 0}, %{"step" => 1}]},
      "optimizer" => %{},
      "rng" => %{}
    }

    assert {:error, :trl_contract_runtime_mismatch} =
             TRLTrainer.start_reinforcement(trainer, %{model: "unused"},
               dispatch_id: "no-worker",
               num_generations: 3,
               imp_reinforcement_contract: protocol_contract
             )

    assert Registry.lookup(Imp.Clients.TRLWorker.Registry, trainer.worker_key) == []
  end
end
