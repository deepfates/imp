defmodule Imp.Clients.TRLDeployment do
  @moduledoc """
  Runs a verified TRL LoRA artifact through a caller-supplied trusted runtime.

  A saved `TrainingJob` owns the immutable artifact and base-model identity.
  The caller reconstructs the pinned `TRLTrainer` runtime explicitly;
  executable paths are never restored from the saved job. Startup verifies the
  complete artifact in Elixir, initializes the exact trainer model, and asks
  the pinned worker to load the saved adapter. The worker must report the same
  artifact identity and adapter-tensor digest retained at training time before
  the returned LM can generate.
  """

  alias Imp.Clients.{TrainingJob, TRLArtifact, TRLLM, TRLTrainer, TRLWorker}

  @enforce_keys [:kind, :artifact_path, :artifact_sha256, :lm, :worker]
  defstruct [:kind, :artifact_path, :artifact_sha256, :adapter_sha256, :lm, :worker]

  @type t :: %__MODULE__{
          kind: :base | :adapter,
          artifact_path: Path.t(),
          artifact_sha256: String.t(),
          adapter_sha256: String.t() | nil,
          lm: TRLLM.t(),
          worker: pid()
        }

  @doc "Loads a verified completed TRL job into a trusted pinned trainer runtime."
  @spec start(TrainingJob.t(), TRLTrainer.t()) :: {:ok, t()} | {:error, term()}
  def start(%TrainingJob{} = job, %TRLTrainer{} = trainer) do
    with {:ok, manifest} <- TRLArtifact.verify_job(job),
         {:ok, expected_adapter_sha256} <- adapter_digest(job.result_model),
         {:ok, worker} <- start_worker(job, trainer),
         {:ok, identity} <- request(trainer, worker, %{"op" => "initialize"}),
         :ok <- validate_base_identity(job, trainer, identity),
         {:ok, loaded} <-
           request(trainer, worker, %{
             "op" => "deploy_artifact",
             "artifact_path" => Path.expand(job.result_model),
             "artifact_sha256" => manifest["payload_sha256"]
           }),
         :ok <- validate_loaded(job, expected_adapter_sha256, loaded) do
      {:ok,
       %__MODULE__{
         kind: :adapter,
         artifact_path: Path.expand(job.result_model),
         artifact_sha256: manifest["payload_sha256"],
         adapter_sha256: expected_adapter_sha256,
         lm: %TRLLM{
           model: Path.expand(job.result_model),
           worker_key: deployment_key(job),
           artifact_sha256: manifest["payload_sha256"]
         },
         worker: worker
       }}
    else
      {:error, _reason} = error ->
        _ = stop(job)
        error
    end
  rescue
    error ->
      _ = stop(job)
      {:error, {:trl_deployment_start_failed, Exception.message(error)}}
  end

  def start(%TrainingJob{}, _trainer), do: {:error, :trl_deployment_requires_trusted_trainer}
  def start(_job, _trainer), do: {:error, :invalid_trl_deployment}

  @doc "Starts the exact pinned base policy for evaluation before training."
  @spec start_base(TRLTrainer.t()) :: {:ok, t()} | {:error, term()}
  def start_base(%TRLTrainer{} = trainer) do
    key = base_deployment_key(trainer)

    with {:ok, worker} <- start_base_worker(trainer, key),
         {:ok, identity} <- request(trainer, worker, %{"op" => "initialize"}),
         :ok <- validate_base_path(trainer, identity),
         {:ok, loaded} <-
           request(trainer, worker, %{
             "op" => "deploy_base",
             "model" => identity["model"],
             "artifact_sha256" => identity["base_model_sha256"]
           }),
         :ok <- validate_base_loaded(identity, loaded) do
      {:ok,
       %__MODULE__{
         kind: :base,
         artifact_path: Path.expand(trainer.model_path),
         artifact_sha256: identity["base_model_sha256"],
         adapter_sha256: nil,
         lm: %TRLLM{
           model: identity["model"],
           worker_key: key,
           artifact_sha256: identity["base_model_sha256"]
         },
         worker: worker
       }}
    else
      {:error, _reason} = error ->
        stop_key(key)
        error
    end
  rescue
    error -> {:error, {:trl_base_deployment_start_failed, Exception.message(error)}}
  end

  def start_base(_trainer), do: {:error, :trl_base_deployment_requires_trusted_trainer}

  @doc "Stops the worker serving a deployment or completed TRL job."
  @spec stop(t() | TrainingJob.t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{worker: worker}) when is_pid(worker), do: stop_worker(worker)

  def stop(%TrainingJob{} = job) do
    case Registry.lookup(Imp.Clients.TRLWorker.Registry, deployment_key(job)) do
      [{worker, _}] -> stop_worker(worker)
      [] -> :ok
    end
  end

  def stop(_value), do: {:error, :invalid_trl_deployment}

  defp start_worker(job, trainer) do
    TRLWorker.start(%{
      session_id: "deployment:" <> job.id,
      registry_key: deployment_key(job),
      python: trainer.python,
      worker_script: trainer.worker_script,
      root: deployment_root(job, trainer),
      model_path: trainer.model_path,
      contract_path: trainer.contract_path
    })
  end

  defp start_base_worker(trainer, key) do
    TRLWorker.start(%{
      session_id: "base-deployment",
      registry_key: key,
      python: trainer.python,
      worker_script: trainer.worker_script,
      root: Path.join([Path.expand(trainer.root), "deployments", "base-" <> key_digest(key)]),
      model_path: trainer.model_path,
      contract_path: trainer.contract_path
    })
  end

  defp request(trainer, worker, payload),
    do: TRLWorker.request(worker, payload, trainer.timeout)

  defp stop_worker(worker) do
    case TRLWorker.stop(worker) do
      :ok -> :ok
      {:error, reason} -> {:error, {:trl_deployment_stop_failed, reason}}
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, reason -> {:error, {:trl_deployment_stop_failed, reason}}
  end

  defp adapter_digest(root) do
    path = Path.join(Path.expand(root), "trl-observation.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"trainable_after_sha256" => digest}} when is_binary(digest) and digest != "" <-
           Jason.decode(bytes) do
      {:ok, digest}
    else
      _ -> {:error, :trl_deployment_adapter_identity_missing}
    end
  end

  defp validate_base_identity(job, trainer, identity) do
    expected_path = Path.expand(trainer.model_path)

    cond do
      not is_map(identity) ->
        {:error, :trl_deployment_invalid_base_identity}

      Path.expand(identity["model_path"] || "") != expected_path ->
        {:error, :trl_deployment_base_path_mismatch}

      identity["model"] != job.model ->
        {:error, :trl_deployment_base_model_mismatch}

      true ->
        :ok
    end
  end

  defp validate_base_path(trainer, identity) do
    if is_map(identity) and
         Path.expand(identity["model_path"] || "") == Path.expand(trainer.model_path) and
         is_binary(identity["model"]) and is_binary(identity["base_model_sha256"]),
       do: :ok,
       else: {:error, :trl_base_deployment_identity_mismatch}
  end

  defp validate_base_loaded(identity, loaded) do
    if is_map(loaded) and loaded["model"] == identity["model"] and
         loaded["artifact_sha256"] == identity["base_model_sha256"],
       do: :ok,
       else: {:error, :trl_base_deployment_identity_mismatch}
  end

  defp validate_loaded(job, adapter_sha256, loaded) do
    expected_path = Path.expand(job.result_model)
    expected_artifact = job.metadata[:artifact_sha256] || job.metadata["artifact_sha256"]

    cond do
      not is_map(loaded) ->
        {:error, :trl_deployment_invalid_loaded_identity}

      loaded["model"] != expected_path ->
        {:error, :trl_deployment_artifact_path_mismatch}

      loaded["artifact_sha256"] != expected_artifact ->
        {:error, :trl_deployment_artifact_identity_mismatch}

      loaded["adapter_sha256"] != adapter_sha256 ->
        {:error, :trl_deployment_adapter_identity_mismatch}

      true ->
        :ok
    end
  end

  defp deployment_key(job) do
    digest = job.metadata[:artifact_sha256] || job.metadata["artifact_sha256"] || "missing"
    {:trl_deployment, Path.expand(job.result_model || "missing"), digest}
  end

  defp deployment_root(job, trainer) do
    Path.join([Path.expand(trainer.root), "deployments", key_digest(deployment_key(job))])
  end

  defp base_deployment_key(trainer),
    do:
      {:trl_base_deployment, Path.expand(trainer.model_path), Path.expand(trainer.contract_path)}

  defp key_digest(key) do
    key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp stop_key(key) do
    case Registry.lookup(Imp.Clients.TRLWorker.Registry, key) do
      [{worker, _}] -> stop_worker(worker)
      [] -> :ok
    end
  end
end
