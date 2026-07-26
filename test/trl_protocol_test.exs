defmodule Imp.TRLProtocolTest do
  use ExUnit.Case

  alias Imp.Clients.TRLProtocol

  test "canonical identities are key-order independent and bind nested values" do
    left = %{"z" => [%{"b" => 2, "a" => 1}], "a" => true}
    right = %{"a" => true, "z" => [%{"a" => 1, "b" => 2}]}

    assert TRLProtocol.canonical_json(left) == ~s({"a":true,"z":[{"a":1,"b":2}]})
    assert TRLProtocol.digest(left) == TRLProtocol.digest(right)

    refute TRLProtocol.digest(left) ==
             TRLProtocol.digest(put_in(right, ["z", Access.at(0), "b"], 3))
  end

  test "canonical JSON follows CPython finite-float spelling" do
    assert TRLProtocol.canonical_json(%{
             "fixed" => 1.0e15,
             "negative_zero" => -0.0,
             "positive_exponent" => 1.0e16,
             "padded_exponent" => 1.0e-7,
             "subnormal" => 5.0e-324
           }) ==
             ~s({"fixed":1000000000000000.0,"negative_zero":-0.0,"padded_exponent":1e-07,"positive_exponent":1e+16,"subnormal":5e-324})
  end

  test "session recursively allowlists the pinned engine, dataset, schedule, optimizer, and RNG" do
    session = TRLProtocol.session!(session_attrs())
    assert :ok = TRLProtocol.validate(session)
    assert session["engine"] == TRLProtocol.engine_identity()

    unknown = put_in(session, ["dataset", "untrusted_python"], "callback.py")

    assert {:error, {:trl_protocol_keys_mismatch, _expected, _actual}} =
             TRLProtocol.validate(unknown)

    missing = update_in(session["prompt_schedule"]["steps"], &Enum.drop(&1, -1))
    assert {:error, :trl_protocol_digest_mismatch} = TRLProtocol.validate(missing)

    wrong_engine = session_attrs() |> put_in(["engine", "revision"], "floating-main")
    assert {:error, :trl_protocol_engine_identity_mismatch} = TRLProtocol.session(wrong_engine)
  end

  test "updates reject missing, reordered, replay-shaped, and mismatched behavior fields" do
    update = TRLProtocol.update!(update_attrs())
    assert :ok = TRLProtocol.validate(update)

    missing_logprobs =
      update_in(
        update_attrs(),
        ["groups", Access.at(0), "samples", Access.at(0)],
        &Map.delete(&1, "behavior_logprobs")
      )

    assert {:error, {:trl_protocol_keys_mismatch, _expected, _actual}} =
             TRLProtocol.update(missing_logprobs)

    reordered = put_in(update_attrs(), ["groups", Access.at(0), "group_position"], 1)
    assert {:error, :trl_protocol_group_order_mismatch} = TRLProtocol.update(reordered)

    wrong_mask =
      put_in(
        update_attrs(),
        ["groups", Access.at(0), "samples", Access.at(0), "completion_mask"],
        [1]
      )

    assert {:error, {:invalid_trl_protocol_mask, :completion_mask}} =
             TRLProtocol.update(wrong_mask)

    wrong_logprobs =
      put_in(
        update_attrs(),
        ["groups", Access.at(0), "samples", Access.at(0), "behavior_logprobs"],
        [-0.1]
      )

    assert {:error, :invalid_trl_protocol_behavior_logprobs} = TRLProtocol.update(wrong_logprobs)

    wrong_prompt =
      put_in(
        update_attrs(),
        ["groups", Access.at(0), "prompt", Access.at(0), "content"],
        "different"
      )

    assert {:error, :trl_protocol_prompt_digest_mismatch} = TRLProtocol.update(wrong_prompt)

    wrong_completion =
      put_in(
        update_attrs(),
        ["groups", Access.at(0), "samples", Access.at(0), "completion"],
        "different"
      )

    assert {:error, :trl_protocol_completion_digest_mismatch} =
             TRLProtocol.update(wrong_completion)

    wrong_idempotency = Map.put(update_attrs(), "idempotency_key", "another-step")

    assert {:error, :trl_protocol_idempotency_key_mismatch} =
             TRLProtocol.update(wrong_idempotency)
  end

  test "receipt, checkpoint, and artifact identities form a closed durable chain" do
    checkpoint = TRLProtocol.checkpoint!(checkpoint_attrs())

    receipt =
      TRLProtocol.receipt!(%{
        "session_id" => "session-1",
        "idempotency_key" => "step-1",
        "accepted_update_sha256" => digest("update"),
        "trainer_step" => 1,
        "artifact" => transition("artifact"),
        "optimizer" => transition("optimizer"),
        "rng" => transition("rng"),
        "checkpoint" => %{
          "path" => "trainer-checkpoint.json",
          "payload_sha256" => checkpoint["payload_sha256"]
        }
      })

    artifact =
      TRLProtocol.artifact!(%{
        "session_id" => "session-1",
        "base_model" => "local/base",
        "base_model_sha256" => digest("base"),
        "trainer_step" => 1,
        "checkpoint_sha256" => checkpoint["payload_sha256"],
        "receipt_sha256s" => [receipt["payload_sha256"]],
        "files" => [
          %{"path" => "adapter.safetensors", "sha256" => digest("weights"), "size" => 42}
        ]
      })

    assert :ok = TRLProtocol.validate(checkpoint)
    assert :ok = TRLProtocol.validate(receipt)
    assert :ok = TRLProtocol.validate(artifact)

    tampered = put_in(artifact, ["files", Access.at(0), "size"], 43)
    assert {:error, :trl_protocol_digest_mismatch} = TRLProtocol.validate(tampered)

    unsafe = artifact |> unseal() |> put_in(["files", Access.at(0), "path"], "../escape.bin")
    assert {:error, :trl_protocol_unsafe_artifact_path} = TRLProtocol.artifact(unsafe)
  end

  defp session_attrs do
    %{
      "session_id" => "session-1",
      "engine" => TRLProtocol.engine_identity(),
      "dataset" => %{
        "train_sha256" => digest("train"),
        "validation_sha256" => digest("validation"),
        "ordered_train_row_sha256s" => [digest("row-1"), digest("row-2")]
      },
      "prompt_schedule" => %{
        "selector" => "imp_grpo_v1",
        "steps" => [
          %{"step" => 0, "ordered_row_sha256s" => [digest("row-2")]},
          %{"step" => 1, "ordered_row_sha256s" => [digest("row-1")]}
        ]
      },
      "behavior_policy" => behavior(),
      "optimizer" => %{
        "name" => "grpo",
        "config_sha256" => digest("config"),
        "num_generations" => 2
      },
      "rng" => %{"algorithm" => "exsss", "state_sha256" => digest("rng")}
    }
  end

  defp update_attrs do
    prompt = [%{"role" => "user", "content" => "prompt"}]
    prompt_sha256 = TRLProtocol.digest(%{"messages" => prompt})

    sample = fn position, completion ->
      %{
        "position" => position,
        "prompt_sha256" => prompt_sha256,
        "prompt_token_ids" => [11, 12],
        "prompt_mask" => [1, 1],
        "completion" => completion,
        "completion_sha256" => TRLProtocol.digest(%{"completion" => completion}),
        "completion_token_ids" => [21, 22],
        "completion_mask" => [1, 1],
        "behavior_logprobs" => [-0.2, -0.3],
        "reward" => position * 1.0
      }
    end

    %{
      "session_id" => "session-1",
      "session_payload_sha256" => digest("session"),
      "step_id" => "step-1",
      "idempotency_key" => "step-1",
      "trainer_step" => 0,
      "behavior_policy" => behavior(),
      "optimizer" => %{"global_step" => 0, "state_sha256" => digest("optimizer")},
      "rng" => %{"algorithm" => "torch", "state_sha256" => digest("rng")},
      "groups" => [
        %{
          "batch_id" => "batch-1",
          "group_id" => "row-1/main/0",
          "group_position" => 0,
          "predictor" => "main",
          "prompt" => prompt,
          "prompt_sha256" => prompt_sha256,
          "samples" => [sample.(0, "a"), sample.(1, "b")]
        }
      ]
    }
  end

  defp checkpoint_attrs do
    %{
      "session_id" => "session-1",
      "trainer_step" => 1,
      "accepted_update_sha256s" => [digest("update")],
      "artifact_sha256" => digest("artifact"),
      "optimizer" => %{"global_step" => 1, "state_sha256" => digest("optimizer")},
      "rng" => %{"algorithm" => "torch", "state_sha256" => digest("rng")}
    }
  end

  defp behavior do
    %{
      "model" => "local/base",
      "artifact_sha256" => digest("base"),
      "tokenizer_sha256" => digest("tokenizer")
    }
  end

  defp transition(name),
    do: %{"before_sha256" => digest("#{name}-before"), "after_sha256" => digest("#{name}-after")}

  defp digest(value), do: TRLProtocol.digest(%{"value" => value})
  defp unseal(value), do: Map.drop(value, ["type", "schema_version", "payload_sha256"])
end
