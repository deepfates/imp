defmodule Imp.TRLWorkerTest do
  use ExUnit.Case, async: false

  alias Imp.Clients.{TRLLM, TRLProtocol, TRLTrainer, TRLWorker}

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
end
