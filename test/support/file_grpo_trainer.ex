defmodule Imp.Test.FileGRPOTrainer do
  @moduledoc false
  @behaviour Imp.Clients.Trainer

  defstruct [:root, :runtime_mode]

  @impl true
  def supported_methods(_trainer), do: [:grpo]

  @impl true
  def start_reinforcement(trainer, lm, opts) do
    dispatch_id = Keyword.fetch!(opts, :dispatch_id)
    record(trainer, "start")

    contract = Keyword.fetch!(opts, :imp_reinforcement_contract)

    protocol =
      Imp.Clients.TRLProtocol.session!(%{
        "session_id" => dispatch_id,
        "engine" => Imp.Clients.TRLProtocol.engine_identity(),
        "dataset" => Map.fetch!(contract, "dataset"),
        "prompt_schedule" => Map.fetch!(contract, "prompt_schedule"),
        "behavior_policy" => %{
          "model" => Map.fetch!(lm, :model),
          "artifact_sha256" =>
            Imp.Clients.TRLProtocol.digest(%{"model" => Map.fetch!(lm, :model)}),
          "tokenizer_sha256" =>
            Imp.Clients.TRLProtocol.digest(%{"tokenizer" => "deterministic-byte-v1"})
        },
        "optimizer" => Map.fetch!(contract, "optimizer"),
        "rng" => Map.fetch!(contract, "rng")
      })

    write_json(Path.join(trainer.root, "session-protocol.json"), protocol)

    session =
      Imp.Clients.ReinforcementSession.new(%{
        id: dispatch_id,
        provider: :file_fixture,
        model: lm,
        pending_batch_ids: ["batch-0"],
        current_model: Map.fetch!(lm, :model),
        metadata: %{protocol_payload_sha256: protocol["payload_sha256"]}
      })

    save_session(trainer, session)
    if trainer.runtime_mode == :hang_after_start, do: Process.sleep(5_000)
    {:ok, session}
  end

  @impl true
  def reconcile_reinforcement(trainer, dispatch_id) do
    record(trainer, "reconcile")

    case load_session(trainer) do
      %Imp.Clients.ReinforcementSession{id: ^dispatch_id} = session -> {:ok, session}
      _other -> {:error, :reinforcement_session_not_found}
    end
  end

  @impl true
  def reinforcement_status(_trainer, session), do: {:ok, session}

  @impl true
  def reinforcement_step(trainer, session, groups, opts) do
    record(trainer, "step")
    rewards = for group <- groups, sample <- group.group, do: sample.reward
    File.write!(Path.join(trainer.root, "rewards.json"), Jason.encode!(rewards), [:sync])

    protocol =
      trainer.root |> Path.join("session-protocol.json") |> File.read!() |> Jason.decode!()

    [group] = Imp.Optimizer.Report.json_projection(groups)
    prepared = prepare_group(group)

    update =
      Imp.Clients.TRLProtocol.update!(%{
        "session_id" => session.id,
        "session_payload_sha256" => protocol["payload_sha256"],
        "step_id" => Keyword.fetch!(opts, :step_id),
        "idempotency_key" => Keyword.fetch!(opts, :idempotency_key),
        "trainer_step" => 0,
        "behavior_policy" => protocol["behavior_policy"],
        "optimizer" => %{
          "global_step" => 0,
          "state_sha256" => Imp.Clients.TRLProtocol.digest(%{"optimizer" => "initial"})
        },
        "rng" => protocol["rng"],
        "groups" => [prepared]
      })

    write_json(
      Path.join(trainer.root, "prepared-update.json"),
      Map.delete(update, "payload_sha256")
    )

    write_json(Path.join(trainer.root, "sealed-update.json"), update)
    ids = Enum.map(groups, & &1.batch_id)
    updated = Imp.Clients.ReinforcementSession.fulfill(session, ids)
    save_session(trainer, updated)
    {:ok, updated}
  end

  @impl true
  def terminate_reinforcement(trainer, session) do
    record(trainer, "terminate")
    updated = %{session | status: :succeeded, pending_batch_ids: []}
    save_session(trainer, updated)
    {:ok, updated}
  end

  @impl true
  def final_model_artifact(trainer, _session) do
    artifact = Path.join(trainer.root, "artifact")
    File.mkdir_p!(artifact)
    File.write!(Path.join(artifact, "weights.fixture"), "stable-callback-resume\n", [:sync])
    {:ok, artifact}
  end

  def events(root) do
    case File.read(Path.join(root, "events")) do
      {:ok, value} -> String.split(value, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp record(trainer, event) do
    File.mkdir_p!(trainer.root)
    File.write!(Path.join(trainer.root, "events"), event <> "\n", [:append, :sync])
  end

  defp save_session(trainer, session) do
    path = Path.join(trainer.root, "session.term")
    temporary = path <> ".tmp"
    File.write!(temporary, :erlang.term_to_binary(session, [:deterministic]), [:sync])
    File.rename!(temporary, path)
  end

  defp load_session(trainer) do
    trainer.root
    |> Path.join("session.term")
    |> File.read!()
    |> :erlang.binary_to_term()
  rescue
    File.Error -> nil
  end

  defp prepare_group(group) do
    messages = group["group"] |> hd() |> Map.fetch!("messages")
    prompt_sha = Imp.Clients.TRLProtocol.digest(%{"messages" => messages})
    prompt_tokens = :binary.bin_to_list(Imp.Clients.TRLProtocol.canonical_json(messages))

    samples =
      group["group"]
      |> Enum.with_index()
      |> Enum.map(fn {sample, position} ->
        completion = sample["completion"]["content"]
        completion_tokens = :binary.bin_to_list(completion)

        %{
          "position" => position,
          "prompt_sha256" => prompt_sha,
          "prompt_token_ids" => prompt_tokens,
          "prompt_mask" => List.duplicate(1, length(prompt_tokens)),
          "completion" => completion,
          "completion_sha256" => Imp.Clients.TRLProtocol.digest(%{"completion" => completion}),
          "completion_token_ids" => completion_tokens,
          "completion_mask" => List.duplicate(1, length(completion_tokens)),
          "behavior_logprobs" => List.duplicate(0.0, length(completion_tokens)),
          "reward" => sample["reward"]
        }
      end)

    %{
      "batch_id" => group["batch_id"],
      "group_id" => inspect(group["group_id"]),
      "group_position" => 0,
      "predictor" => inspect(group["predictor"]),
      "prompt" => messages,
      "prompt_sha256" => prompt_sha,
      "samples" => samples
    }
  end

  defp write_json(path, value) do
    temporary = path <> ".tmp"
    File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
    File.rename!(temporary, path)
  end
end
