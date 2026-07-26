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

    session =
      Imp.Clients.ReinforcementSession.new(%{
        id: dispatch_id,
        provider: :file_fixture,
        model: lm,
        pending_batch_ids: ["batch-0"],
        current_model: Map.fetch!(lm, :model)
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
  def reinforcement_step(trainer, session, groups, _opts) do
    record(trainer, "step")
    rewards = for group <- groups, sample <- group.group, do: sample.reward
    File.write!(Path.join(trainer.root, "rewards.json"), Jason.encode!(rewards), [:sync])
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
end
