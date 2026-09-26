defmodule Imp.Test.TRLConformanceLM do
  @behaviour Imp.LM
  defstruct [:model]

  @impl true
  def generate(_lm, messages, opts) do
    prompt = Enum.map_join(messages, "\n", &Map.get(&1, :content, ""))
    answer = if String.contains?(prompt, "alpha"), do: "alpha", else: "other"
    {:ok, %{answer: "#{answer}-#{Keyword.get(opts, :rollout_id, 0)}"}}
  end
end

defmodule Imp.Test.TRLConformanceTrainer do
  @moduledoc false
  @behaviour Imp.Clients.Trainer

  defstruct [:server]

  @impl true
  def supported_methods(%__MODULE__{}), do: [:grpo]

  @impl true
  def start_reinforcement(%__MODULE__{server: server}, lm, opts) do
    Imp.Test.TRLConformanceServer.start_session(server, lm, opts)
  end

  @impl true
  def reconcile_reinforcement(%__MODULE__{server: server}, dispatch_id) do
    Imp.Test.TRLConformanceServer.reconcile(server, dispatch_id)
  end

  @impl true
  def reinforcement_status(%__MODULE__{server: server}, session) do
    Imp.Test.TRLConformanceServer.status(server, session)
  end

  @impl true
  def reinforcement_step(%__MODULE__{server: server}, session, groups, opts) do
    Imp.Test.TRLConformanceServer.step(server, session, groups, opts)
  end

  @impl true
  def terminate_reinforcement(%__MODULE__{server: server}, session) do
    Imp.Test.TRLConformanceServer.finish(server, session)
  end

  @impl true
  def final_model_artifact(%__MODULE__{server: server}, session) do
    Imp.Test.TRLConformanceServer.artifact(server, session)
  end

  @impl true
  def reinforcement_artifact(_trainer, session, selection) do
    with {:ok, manifest} <-
           Imp.Clients.TRLArtifact.verify(selection.path, selection.artifact_sha256),
         true <- manifest["session_id"] == session.id,
         true <- manifest["trainer_step"] == selection.step do
      {:ok, Map.put(selection, :checkpoint_sha256, manifest["checkpoint_sha256"])}
    else
      false -> {:error, :trl_conformance_selected_artifact_mismatch}
      {:error, _reason} = error -> error
    end
  end
end

defmodule Imp.Test.TRLConformanceServer do
  @moduledoc false
  use GenServer

  alias Imp.Clients.{ReinforcementSession, TRLProtocol}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def start_session(server, lm, opts), do: GenServer.call(server, {:start, lm, opts})
  def reconcile(server, dispatch_id), do: GenServer.call(server, {:reconcile, dispatch_id})
  def status(server, session), do: GenServer.call(server, {:status, session})

  def step(server, session, groups, opts),
    do: GenServer.call(server, {:step, session, groups, opts})

  def finish(server, session), do: GenServer.call(server, {:terminate, session})
  def artifact(server, session), do: GenServer.call(server, {:artifact, session})
  def submit_envelope(server, update), do: GenServer.call(server, {:submit_envelope, update})
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    File.mkdir_p!(root)

    {:ok,
     %{
       root: root,
       session: nil,
       protocol: nil,
       updates: %{},
       receipts: [],
       step: 0,
       failure_mode: Keyword.get(opts, :failure_mode),
       failure_injected?: false
     }}
  end

  @impl true
  def handle_call({:start, lm, opts}, _from, %{session: nil} = state) do
    contract = Keyword.fetch!(opts, :imp_reinforcement_contract)
    dispatch_id = Keyword.fetch!(opts, :dispatch_id)
    model = Map.fetch!(lm, :model)
    base_sha256 = TRLProtocol.digest(%{"model" => model})
    tokenizer_sha256 = TRLProtocol.digest(%{"tokenizer" => "deterministic-byte-v1"})

    protocol =
      TRLProtocol.session!(%{
        "session_id" => dispatch_id,
        "engine" => TRLProtocol.engine_identity(),
        "dataset" => Map.fetch!(contract, "dataset"),
        "prompt_schedule" => Map.fetch!(contract, "prompt_schedule"),
        "behavior_policy" => %{
          "model" => model,
          "artifact_sha256" => base_sha256,
          "tokenizer_sha256" => tokenizer_sha256
        },
        "optimizer" => Map.fetch!(contract, "optimizer"),
        "rng" => Map.fetch!(contract, "rng")
      })

    pending = pending_ids(protocol, 0)

    session =
      ReinforcementSession.new(%{
        id: dispatch_id,
        provider: :trl,
        model: lm,
        status: :running,
        pending_batch_ids: pending,
        current_model: model,
        metadata: %{
          protocol_payload_sha256: protocol["payload_sha256"],
          tokenizer_sha256: tokenizer_sha256,
          base_artifact_sha256: base_sha256
        }
      })

    {:reply, {:ok, session}, %{state | session: session, protocol: protocol}}
  rescue
    error -> {:reply, {:error, {:invalid_trl_protocol_session, Exception.message(error)}}, state}
  end

  def handle_call({:start, _lm, opts}, _from, state) do
    dispatch_id = Keyword.get(opts, :dispatch_id)

    if state.session.id == dispatch_id do
      {:reply, {:ok, state.session}, state}
    else
      {:reply, {:error, :trl_conformance_session_already_started}, state}
    end
  end

  def handle_call({:reconcile, dispatch_id}, _from, state) do
    if state.session && state.session.id == dispatch_id,
      do: {:reply, {:ok, state.session}, state},
      else: {:reply, {:error, :reinforcement_session_not_found}, state}
  end

  def handle_call({:status, session}, _from, state) do
    with :ok <- same_session(state, session) do
      {:reply, {:ok, state.session}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:step, session, groups, opts}, _from, state) do
    with :ok <- same_session(state, session),
         {:ok, update} <- build_update(state, groups, opts),
         {:ok, state} <- accept_update(state, update) do
      if state.failure_mode == :after_first_accept and not state.failure_injected? do
        {:reply, {:error, :trl_conformance_transport_lost_after_accept},
         %{state | failure_injected?: true}}
      else
        {:reply, {:ok, state.session}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, {:reinforcement_step_not_accepted, reason}}, state}
    end
  end

  def handle_call({:submit_envelope, update}, _from, state) do
    with :ok <- TRLProtocol.validate(update),
         true <-
           update["session_id"] == state.session.id ||
             {:error, :trl_protocol_session_identity_mismatch},
         true <-
           update["session_payload_sha256"] == state.protocol["payload_sha256"] ||
             {:error, :trl_protocol_session_payload_mismatch},
         {:ok, state} <- accept_update(state, update) do
      {:reply, {:ok, state.session}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:terminate, session}, _from, state) do
    expected = state.protocol["prompt_schedule"]["steps"] |> length()

    with :ok <- same_session(state, session),
         true <- state.step == expected || {:error, :trl_protocol_incomplete_training},
         true <- state.session.pending_batch_ids == [] || {:error, :trl_protocol_pending_batches} do
      terminated = %{state.session | status: :succeeded}
      {:reply, {:ok, terminated}, %{state | session: terminated}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:artifact, session}, _from, state) do
    with :ok <- same_session(state, session),
         true <- session.status == :succeeded || {:error, :trl_protocol_session_not_succeeded},
         path when is_binary(path) <-
           session.result_model || {:error, :trl_protocol_artifact_missing},
         {:ok, _manifest} <-
           Imp.Clients.TRLArtifact.verify(path, session.metadata.artifact_sha256) do
      {:reply, {:ok, path}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  defp build_update(state, groups, opts) do
    expected_ids = state.session.pending_batch_ids
    actual_ids = Enum.map(groups, &to_string(Map.fetch!(&1, :batch_id)))

    if actual_ids != expected_ids do
      {:error, {:trl_protocol_batch_order_mismatch, expected_ids, actual_ids}}
    else
      behavior = %{
        "model" => state.session.current_model,
        "artifact_sha256" => current_artifact_sha256(state),
        "tokenizer_sha256" => state.session.metadata.tokenizer_sha256
      }

      TRLProtocol.update(%{
        "session_id" => state.session.id,
        "session_payload_sha256" => state.protocol["payload_sha256"],
        "step_id" => Keyword.fetch!(opts, :step_id),
        "idempotency_key" => Keyword.fetch!(opts, :idempotency_key),
        "trainer_step" => state.step,
        "behavior_policy" => behavior,
        "optimizer" => optimizer_state(state),
        "rng" => rng_state(state),
        "groups" => Enum.with_index(groups, &encode_group/2)
      })
    end
  rescue
    error -> {:error, {:trl_protocol_update_build_failed, Exception.message(error)}}
  end

  defp encode_group(group, group_position) do
    samples = Map.fetch!(group, :group)
    messages = samples |> hd() |> Map.fetch!(:messages) |> normalize_messages()
    prompt_sha256 = TRLProtocol.digest(%{"messages" => messages})
    prompt_tokens = messages |> TRLProtocol.canonical_json() |> :binary.bin_to_list()

    %{
      "batch_id" => to_string(Map.fetch!(group, :batch_id)),
      "group_id" => inspect(Map.fetch!(group, :group_id)),
      "group_position" => group_position,
      "predictor" => to_string(Map.fetch!(group, :predictor)),
      "prompt" => messages,
      "prompt_sha256" => prompt_sha256,
      "samples" =>
        samples
        |> Enum.with_index()
        |> Enum.map(fn {sample, position} ->
          sample_messages = sample |> Map.fetch!(:messages) |> normalize_messages()

          if TRLProtocol.digest(%{"messages" => sample_messages}) != prompt_sha256,
            do: raise(ArgumentError, "group contains multiple prompt identities")

          completion = sample |> Map.fetch!(:completion) |> Map.fetch!(:content)
          completion_tokens = :binary.bin_to_list(completion)

          %{
            "position" => position,
            "prompt_sha256" => prompt_sha256,
            "prompt_token_ids" => prompt_tokens,
            "prompt_mask" => List.duplicate(1, length(prompt_tokens)),
            "completion" => completion,
            "completion_sha256" => TRLProtocol.digest(%{"completion" => completion}),
            "completion_token_ids" => completion_tokens,
            "completion_mask" => List.duplicate(1, length(completion_tokens)),
            "behavior_logprobs" => Enum.map(completion_tokens, &(-((rem(&1, 17) + 1) / 10))),
            "reward" => Map.fetch!(sample, :reward)
          }
        end)
    }
  end

  defp accept_update(state, update) do
    step_id = update["step_id"]

    case Map.fetch(state.updates, step_id) do
      {:ok, %{update: previous}} ->
        if previous["payload_sha256"] == update["payload_sha256"],
          do: {:ok, state},
          else: {:error, :trl_protocol_replay_payload_mismatch}

      :error ->
        persist_update(state, update)
    end
  end

  defp persist_update(state, update) do
    next_step = state.step + 1
    artifact_parent = Path.join(state.root, "artifacts")
    artifact_dir = Path.join(artifact_parent, "step-#{next_step}")
    staging_dir = Path.join(artifact_parent, ".step-#{next_step}.tmp")
    File.mkdir_p!(staging_dir)

    all_updates =
      state.updates
      |> Map.values()
      |> Enum.map(& &1.update)
      |> Enum.sort_by(& &1["trainer_step"])
      |> Kernel.++([update])

    # The exact sealed intent is synced before the first artifact mutation.
    Enum.with_index(all_updates, 1)
    |> Enum.each(fn {stored_update, update_step} ->
      update_path = Path.join(staging_dir, "update-#{update_step}.json")
      atomic_write(update_path, Jason.encode!(stored_update, pretty: true) <> "\n")
    end)

    weights =
      Jason.encode!(%{
        "accepted_updates" =>
          Enum.map(state.receipts, & &1["accepted_update_sha256"]) ++ [update["payload_sha256"]]
      }) <> "\n"

    weights_path = Path.join(staging_dir, "adapter.safetensors")
    atomic_write(weights_path, weights)
    weights_sha256 = file_digest(weights_path)
    observation_path = Path.join(staging_dir, "trl-observation.json")

    atomic_write(
      observation_path,
      Jason.encode!(%{"trainable_after_sha256" => weights_sha256}, pretty: true) <> "\n"
    )

    next_optimizer =
      transition_optimizer(optimizer_state(state), update["payload_sha256"], next_step)

    next_rng = transition_rng(rng_state(state), update["payload_sha256"])

    checkpoint =
      TRLProtocol.checkpoint!(%{
        "session_id" => state.session.id,
        "trainer_step" => next_step,
        "accepted_update_sha256s" =>
          Enum.map(state.receipts, & &1["accepted_update_sha256"]) ++ [update["payload_sha256"]],
        "artifact_sha256" => weights_sha256,
        "optimizer" => next_optimizer,
        "rng" => next_rng
      })

    checkpoint_path = Path.join(staging_dir, "trainer-checkpoint.json")
    atomic_write(checkpoint_path, Jason.encode!(checkpoint, pretty: true) <> "\n")

    receipt =
      TRLProtocol.receipt!(%{
        "session_id" => state.session.id,
        "idempotency_key" => update["idempotency_key"],
        "accepted_update_sha256" => update["payload_sha256"],
        "trainer_step" => next_step,
        "artifact" => %{
          "before_sha256" => current_artifact_sha256(state),
          "after_sha256" => weights_sha256
        },
        "optimizer" => %{
          "before_sha256" => optimizer_state(state)["state_sha256"],
          "after_sha256" => next_optimizer["state_sha256"]
        },
        "rng" => %{
          "before_sha256" => rng_state(state)["state_sha256"],
          "after_sha256" => next_rng["state_sha256"]
        },
        "checkpoint" => %{
          "path" => "trainer-checkpoint.json",
          "payload_sha256" => checkpoint["payload_sha256"]
        }
      })

    all_receipts = state.receipts ++ [receipt]

    Enum.with_index(all_receipts, 1)
    |> Enum.each(fn {stored_receipt, receipt_step} ->
      receipt_path = Path.join(staging_dir, "receipt-#{receipt_step}.json")
      atomic_write(receipt_path, Jason.encode!(stored_receipt, pretty: true) <> "\n")
    end)

    artifact =
      TRLProtocol.artifact!(%{
        "session_id" => state.session.id,
        "base_model" => state.protocol["behavior_policy"]["model"],
        "base_model_sha256" => state.protocol["behavior_policy"]["artifact_sha256"],
        "trainer_step" => next_step,
        "checkpoint_sha256" => checkpoint["payload_sha256"],
        "receipt_sha256s" =>
          Enum.map(state.receipts, & &1["payload_sha256"]) ++ [receipt["payload_sha256"]],
        "files" =>
          [
            file_entry("adapter.safetensors", weights_path),
            file_entry("trl-observation.json", observation_path),
            file_entry("trainer-checkpoint.json", checkpoint_path)
          ] ++
            Enum.map(1..next_step, fn update_step ->
              relative = "update-#{update_step}.json"
              file_entry(relative, Path.join(staging_dir, relative))
            end) ++
            Enum.map(1..next_step, fn receipt_step ->
              relative = "receipt-#{receipt_step}.json"
              file_entry(relative, Path.join(staging_dir, relative))
            end)
      })

    manifest_path = Path.join(staging_dir, "imp-trl-artifact.json")
    atomic_write(manifest_path, Jason.encode!(artifact, pretty: true) <> "\n")
    File.rename!(staging_dir, artifact_dir)

    completed_ids = Enum.map(update["groups"], & &1["batch_id"])
    pending = pending_ids(state.protocol, next_step)

    session = %{
      state.session
      | current_model: artifact_dir,
        result_model: artifact_dir,
        pending_batch_ids: pending,
        fulfilled_batch_ids: Enum.uniq(state.session.fulfilled_batch_ids ++ completed_ids),
        metadata:
          Map.merge(state.session.metadata, %{
            artifact_sha256: artifact["payload_sha256"],
            checkpoint_sha256: checkpoint["payload_sha256"],
            protocol_payload_sha256: update["payload_sha256"],
            optimizer_state_sha256: next_optimizer["state_sha256"],
            rng_state_sha256: next_rng["state_sha256"]
          })
    }

    stored = %{update: update, receipt: receipt, session: session}

    {:ok,
     %{
       state
       | session: session,
         step: next_step,
         receipts: all_receipts,
         updates: Map.put(state.updates, update["step_id"], stored)
     }}
  end

  defp pending_ids(protocol, step) do
    if step < length(protocol["prompt_schedule"]["steps"]), do: ["trl-batch-#{step}"], else: []
  end

  defp optimizer_state(%{step: step, protocol: protocol}) do
    %{
      "global_step" => step,
      "state_sha256" =>
        TRLProtocol.digest(%{"initial" => protocol["optimizer"]["config_sha256"], "step" => step})
    }
  end

  defp rng_state(%{step: step, protocol: protocol}) do
    %{
      "algorithm" => protocol["rng"]["algorithm"],
      "state_sha256" =>
        TRLProtocol.digest(%{"initial" => protocol["rng"]["state_sha256"], "step" => step})
    }
  end

  defp transition_optimizer(state, update_sha256, next_step) do
    %{
      "global_step" => next_step,
      "state_sha256" =>
        TRLProtocol.digest(%{"before" => state["state_sha256"], "update" => update_sha256})
    }
  end

  defp transition_rng(state, update_sha256) do
    %{
      "algorithm" => state["algorithm"],
      "state_sha256" =>
        TRLProtocol.digest(%{"before" => state["state_sha256"], "update" => update_sha256})
    }
  end

  defp current_artifact_sha256(%{receipts: [], protocol: protocol}),
    do: protocol["behavior_policy"]["artifact_sha256"]

  defp current_artifact_sha256(%{session: session}), do: session.metadata.artifact_sha256

  defp same_session(%{session: %ReinforcementSession{id: id}}, %ReinforcementSession{id: id}),
    do: :ok

  defp same_session(_state, _session), do: {:error, :trl_protocol_session_identity_mismatch}

  defp normalize_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        "role" => to_string(Map.get(message, :role, Map.get(message, "role"))),
        "content" => Map.get(message, :content, Map.get(message, "content", ""))
      }
    end)
  end

  defp file_entry(relative, path) do
    %{"path" => relative, "sha256" => file_digest(path), "size" => File.stat!(path).size}
  end

  defp file_digest(path) do
    "sha256:" <>
      (path
       |> File.read!()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  defp atomic_write(path, content) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, content, [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end
