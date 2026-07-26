defmodule Imp.Clients.TRLTrainer do
  @moduledoc """
  Local, process-supervised TRL reinforcement backend.

  The backend is intentionally narrow: it speaks the versioned
  `Imp.Clients.TRLProtocol` to the bundled worker and supports only GRPO.
  Constructing the backend does not install Python packages or download a
  model. The configured Python environment and model tree must already exist.
  """

  @behaviour Imp.Clients.Trainer

  alias Imp.Clients.{ReinforcementSession, TRLProtocol, TRLWorker}

  @enforce_keys [:python, :model_path, :root, :contract_path]
  defstruct [
    :python,
    :model_path,
    :root,
    :contract_path,
    :worker_script,
    :worker_key,
    timeout: 120_000
  ]

  def new(opts) when is_list(opts) do
    priv = :imp |> :code.priv_dir() |> to_string()

    root = Keyword.fetch!(opts, :root)

    struct!(__MODULE__, %{
      python: Keyword.fetch!(opts, :python),
      model_path: Keyword.fetch!(opts, :model_path),
      root: root,
      contract_path:
        Keyword.get(opts, :contract_path, Path.join(priv, "trl_worker/feasibility-contract.json")),
      worker_script: Keyword.get(opts, :worker_script, Path.join(priv, "trl_worker/worker.py")),
      worker_key: Keyword.get(opts, :worker_key, {:trl_worker, Path.expand(root)}),
      timeout: Keyword.get(opts, :timeout, 120_000)
    })
  end

  @impl true
  def supported_methods(%__MODULE__{}), do: [:grpo]

  @impl true
  def start_reinforcement(%__MODULE__{} = trainer, lm, opts) do
    dispatch_id = Keyword.fetch!(opts, :dispatch_id)
    contract = Keyword.fetch!(opts, :imp_reinforcement_contract)

    with {:ok, worker} <- start_worker(trainer, dispatch_id),
         {:ok, identity} <- request(trainer, worker, %{"op" => "initialize"}),
         :ok <- exact_model(identity, lm, trainer),
         {:ok, protocol} <- build_session(dispatch_id, identity, contract),
         {:ok, bound} <-
           request(trainer, worker, %{"op" => "bind_session", "envelope" => protocol}) do
      {:ok, session(dispatch_id, lm, worker, protocol, bound)}
    else
      {:error, _reason} = error ->
        stop_worker(trainer)
        error
    end
  end

  @impl true
  def reconcile_reinforcement(%__MODULE__{} = trainer, dispatch_id) do
    with {:ok, worker} <- start_worker(trainer, dispatch_id),
         {:ok, result} <- request(trainer, worker, %{"op" => "reconcile"}),
         %{"protocol" => protocol, "model" => model} <- result,
         :ok <- TRLProtocol.validate(protocol) do
      {:ok, session(dispatch_id, %{model: model}, worker, protocol, result)}
    else
      {:error, {:trl_worker, %{"code" => "session_not_found"}}} ->
        stop_worker(trainer)
        {:error, :reinforcement_session_not_found}

      {:error, _reason} = error ->
        stop_worker(trainer)
        error

      other ->
        stop_worker(trainer)
        {:error, {:invalid_trl_reconciliation, other}}
    end
  end

  @impl true
  def reinforcement_status(%__MODULE__{} = trainer, %ReinforcementSession{} = session) do
    with {:ok, result} <- request(trainer, worker!(session), %{"op" => "status"}) do
      {:ok, session_update(result)}
    end
  end

  @impl true
  def reinforcement_step(
        %__MODULE__{} = trainer,
        %ReinforcementSession{} = session,
        groups,
        opts
      ) do
    worker = worker!(session)
    step_id = Keyword.fetch!(opts, :step_id)
    idempotency_key = Keyword.fetch!(opts, :idempotency_key)
    projected_groups = encode_groups(groups)

    with :ok <-
           persist_prepared_stage(trainer, session.id, %{
             "step_id" => step_id,
             "idempotency_key" => idempotency_key,
             "groups" => projected_groups
           }),
         {:ok, prepared} <-
           request(trainer, worker, %{
             "op" => "prepare_update",
             "groups" => projected_groups,
             "step_id" => step_id,
             "idempotency_key" => idempotency_key
           }),
         {:ok, update} <- TRLProtocol.update(prepared),
         {:ok, result} <-
           request(trainer, worker, %{"op" => "apply_update", "envelope" => update}),
         :ok <- validate_mutation_result(result, update) do
      {:ok, session_update(result)}
    else
      {:error, {:trl_worker, %{"accepted" => false} = reason}} ->
        {:error, {:reinforcement_step_not_accepted, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def terminate_reinforcement(
        %__MODULE__{} = trainer,
        %ReinforcementSession{} = session
      ) do
    worker = worker!(session)

    case request(trainer, worker, %{"op" => "terminate"}) do
      {:ok, result} ->
        _ = TRLWorker.stop(worker)
        {:ok, session_update(result)}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def final_model_artifact(
        %__MODULE__{},
        %ReinforcementSession{status: :succeeded, result_model: path}
      )
      when is_binary(path) and path != "",
      do: {:ok, path}

  def final_model_artifact(%__MODULE__{}, %ReinforcementSession{}),
    do: {:error, :reinforcement_artifact_missing}

  defp start_worker(trainer, dispatch_id) do
    TRLWorker.start(%{
      session_id: dispatch_id,
      registry_key: trainer.worker_key,
      python: trainer.python,
      worker_script: trainer.worker_script,
      root: Path.join(Path.expand(trainer.root), safe_session_name(dispatch_id)),
      model_path: trainer.model_path,
      contract_path: trainer.contract_path
    })
  end

  defp stop_worker(trainer) do
    case Registry.lookup(Imp.Clients.TRLWorker.Registry, trainer.worker_key) do
      [{pid, _}] -> TRLWorker.stop(pid)
      [] -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp request(trainer, worker, request) do
    TRLWorker.request(worker, request, trainer.timeout)
  catch
    :exit, reason -> {:error, {:trl_worker_call_exit, reason}}
  end

  defp build_session(dispatch_id, identity, contract) do
    TRLProtocol.session(%{
      "session_id" => dispatch_id,
      "engine" => TRLProtocol.engine_identity(),
      "dataset" => Map.fetch!(contract, "dataset"),
      "prompt_schedule" => Map.fetch!(contract, "prompt_schedule"),
      "behavior_policy" => %{
        "model" => Map.fetch!(identity, "model"),
        "artifact_sha256" => Map.fetch!(identity, "base_model_sha256"),
        "tokenizer_sha256" => Map.fetch!(identity, "tokenizer_sha256")
      },
      "optimizer" => Map.fetch!(contract, "optimizer"),
      "rng" => Map.fetch!(contract, "rng")
    })
  rescue
    error -> {:error, {:invalid_trl_worker_identity, Exception.message(error)}}
  end

  defp exact_model(identity, lm, trainer) do
    configured = Path.expand(trainer.model_path)
    reported = identity |> Map.fetch!("model_path") |> Path.expand()
    lm_model = if is_map(lm), do: Map.get(lm, :model, Map.get(lm, "model")), else: nil

    cond do
      reported != configured -> {:error, :trl_worker_model_path_mismatch}
      lm_model not in [reported, identity["model"]] -> {:error, :trl_worker_lm_model_mismatch}
      true -> :ok
    end
  end

  defp validate_mutation_result(result, update) do
    with %{"receipt" => receipt, "checkpoint" => checkpoint} <- result,
         :ok <- TRLProtocol.validate(receipt),
         :ok <- TRLProtocol.validate(checkpoint),
         true <-
           receipt["accepted_update_sha256"] == update["payload_sha256"] ||
             {:error, :trl_worker_receipt_update_mismatch},
         true <-
           receipt["trainer_step"] == update["trainer_step"] + 1 ||
             {:error, :trl_worker_step_mismatch} do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_trl_mutation_result, other}}
    end
  end

  defp session(dispatch_id, lm, worker, protocol, result) do
    ReinforcementSession.new(%{
      id: dispatch_id,
      provider: :trl,
      model: lm,
      status: Map.get(result, "status", "running"),
      pending_batch_ids: Map.get(result, "pending_batch_ids", []),
      fulfilled_batch_ids: Map.get(result, "fulfilled_batch_ids", []),
      current_model: Map.get(result, "current_model", protocol["behavior_policy"]["model"]),
      result_model: Map.get(result, "result_model"),
      backend_state: %{worker: worker},
      metadata:
        %{
          protocol_payload_sha256: protocol["payload_sha256"],
          tokenizer_sha256: protocol["behavior_policy"]["tokenizer_sha256"],
          base_artifact_sha256: protocol["behavior_policy"]["artifact_sha256"]
        }
        |> Map.merge(Map.get(result, "metadata", %{}))
    })
  end

  defp session_update(result) do
    %{
      status: Map.get(result, "status", "running"),
      pending_batch_ids: Map.get(result, "pending_batch_ids", []),
      current_model: Map.get(result, "current_model"),
      result_model: Map.get(result, "result_model"),
      metadata: Map.get(result, "metadata", %{})
    }
  end

  defp worker!(%ReinforcementSession{backend_state: %{worker: worker}}) when is_pid(worker),
    do: worker

  defp worker!(_session), do: raise(ArgumentError, "TRL worker binding is missing")

  defp safe_session_name(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def encode_groups(groups), do: Imp.Optimizer.Report.json_projection(groups)

  @doc false
  def persist_prepared_stage(%__MODULE__{} = trainer, session_id, stage)
      when is_binary(session_id) and is_map(stage) do
    root =
      trainer.root
      |> Path.expand()
      |> Path.join(safe_session_name(session_id))
      |> Path.join("prepared-stages")

    identity = TRLProtocol.digest(stage) |> String.replace_prefix("sha256:", "")
    path = Path.join(root, identity <> ".json")
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    encoded = Jason.encode!(stage, pretty: true) <> "\n"

    File.mkdir_p!(root)

    try do
      File.write!(temporary, encoded, [:sync])
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  rescue
    error -> {:error, {:trl_prepared_stage_persistence_failed, Exception.message(error)}}
  end
end
