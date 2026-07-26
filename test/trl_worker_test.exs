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
end
