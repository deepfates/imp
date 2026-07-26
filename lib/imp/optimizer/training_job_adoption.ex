defmodule Imp.Optimizer.TrainingJobAdoption do
  @behaviour Imp.Optimizer
  @moduledoc """
  Adopts a verified, already-completed `Imp.Clients.TrainingJob` as a workflow step.

  Adoption performs no training, trainer dispatch, fusion, or artifact mutation. It
  exists so an ordinary consumer can continue a composition such as
  `BetterTogether` from a durable weight artifact produced earlier. Construction
  binds the exact job, verified artifact, base program, and base-model identities.
  Execution verifies all four again before `TrainingJob.rebind/3` starts the
  artifact's supported deployment.

  Only providers with an Imp content verifier are accepted. Currently those are
  local MLX-LM fused artifacts and Imp↔TRL artifacts. A changed job, artifact tree,
  incoming program, or base model fails before rebinding.
  """

  alias Imp.Clients.{MLXLMTrainer, TrainingJob, TRLArtifact}
  alias Imp.Optimizer.TrainingResult
  alias Imp.Training.ChatDataset

  @enforce_keys [
    :job,
    :job_sha256,
    :artifact_sha256,
    :program_sha256,
    :base_model_identity
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          job: TrainingJob.t(),
          job_sha256: String.t(),
          artifact_sha256: String.t(),
          program_sha256: String.t(),
          base_model_identity: map()
        }

  @doc """
  Binds a completed job to the exact compatible program that may later adopt it.

  This constructor reads and verifies durable artifact contents but never starts a
  deployment or invokes a trainer.
  """
  @spec new(TrainingJob.t(), struct()) :: t()
  def new(%TrainingJob{} = job, %_module{} = program) do
    with {:ok, artifact} <- verify_artifact(job),
         {:ok, base_model_identity} <- base_model_identity(job, artifact),
         :ok <- compatible_program(program, base_model_identity),
         {:ok, program_sha256} <- program_sha256(program) do
      %__MODULE__{
        job: job,
        job_sha256: job_sha256(job),
        artifact_sha256: artifact_sha256(job, artifact),
        program_sha256: program_sha256,
        base_model_identity: base_model_identity
      }
    else
      {:error, reason} ->
        raise ArgumentError, "invalid completed training job adoption: #{inspect(reason)}"
    end
  end

  def new(job, program) do
    raise ArgumentError,
          "TrainingJobAdoption.new/2 expects a completed TrainingJob and an Imp program, " <>
            "got: #{inspect({job, program})}"
  end

  @impl true
  def __optimizer__,
    do: %{
      # BetterTogether uses the training-result lifecycle for weight-bearing
      # steps. This value adopts an earlier result; it never performs training.
      kind: :training,
      datasets: %{trainset: :optional, validation: :unsupported},
      result: :training_result
    }

  @impl true
  def run(%__MODULE__{} = adoption, program, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)),
         :ok <- unchanged_job(adoption),
         {:ok, artifact} <- verify_artifact(adoption.job),
         :ok <- unchanged_artifact(adoption, artifact),
         :ok <- unchanged_program(adoption, program),
         :ok <- compatible_program(program, adoption.base_model_identity),
         {:ok, rebound} <- TrainingJob.rebind(adoption.job, program),
         :ok <- verify_rebound(adoption, rebound) do
      {:ok,
       %TrainingResult{
         status: :completed,
         program: rebound,
         job: adoption.job,
         metadata: %{
           operation: :training_job_adoption,
           training_performed: false,
           job_sha256: adoption.job_sha256,
           artifact_sha256: adoption.artifact_sha256,
           source_program_sha256: adoption.program_sha256
         }
       }}
    else
      {:error, reason} -> {:error, {:training_job_adoption_failed, reason}}
    end
  end

  defp verify_artifact(%TrainingJob{status: status}) when status != :succeeded,
    do: {:error, {:training_job_not_completed, status}}

  defp verify_artifact(%TrainingJob{provider: :mlx_lm} = job), do: MLXLMTrainer.verify_job(job)
  defp verify_artifact(%TrainingJob{provider: :trl} = job), do: TRLArtifact.verify_job(job)

  defp verify_artifact(%TrainingJob{provider: provider}),
    do: {:error, {:training_job_adoption_provider_not_content_verifiable, provider}}

  defp base_model_identity(%TrainingJob{provider: :mlx_lm} = job, manifest) do
    with %{
           "model" => model,
           "model_path" => model_path,
           "model_revision" => revision,
           "model_tree_sha256" => tree_sha256
         } <- manifest["spec"],
         true <- job.model == model <> "@" <> revision do
      {:ok,
       %{
         provider: :mlx_lm,
         job_model: job.model,
         repository: model,
         revision: revision,
         path: Path.expand(model_path),
         artifact_sha256: tree_sha256
       }}
    else
      false -> {:error, :mlx_lm_adoption_job_base_model_mismatch}
      _other -> {:error, :mlx_lm_adoption_base_identity_missing}
    end
  end

  defp base_model_identity(%TrainingJob{provider: :trl} = job, manifest) do
    if manifest["base_model"] == job.model do
      {:ok, %{provider: :trl, job_model: job.model}}
    else
      {:error, :trl_adoption_job_base_model_mismatch}
    end
  end

  defp compatible_program(program, %{provider: :mlx_lm} = identity) do
    case program_model(program) do
      {:ok, model} ->
        if model == identity.job_model or model == identity.repository or
             same_path?(model, identity.path),
           do: :ok,
           else: {:error, {:adoption_program_base_model_mismatch, identity, model}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compatible_program(program, %{provider: :trl, job_model: expected}) do
    case program_model(program) do
      {:ok, ^expected} -> :ok
      {:ok, model} -> {:error, {:adoption_program_base_model_mismatch, expected, model}}
      {:error, _reason} = error -> error
    end
  end

  defp unchanged_job(adoption) do
    if secure_equal?(adoption.job_sha256, job_sha256(adoption.job)),
      do: :ok,
      else: {:error, :adoption_job_identity_mismatch}
  end

  defp unchanged_artifact(adoption, artifact) do
    actual = artifact_sha256(adoption.job, artifact)

    if secure_equal?(adoption.artifact_sha256, actual),
      do: :ok,
      else: {:error, :adoption_artifact_identity_mismatch}
  end

  defp unchanged_program(adoption, program) do
    with {:ok, actual} <- program_sha256(program) do
      if secure_equal?(adoption.program_sha256, actual),
        do: :ok,
        else: {:error, :adoption_program_identity_mismatch}
    end
  end

  defp verify_rebound(adoption, rebound) do
    metadata = Imp.ProgramAccess.get_metadata(rebound, :training_artifact)

    with {:ok, model} <- program_model(rebound),
         true <- same_path?(model, adoption.job.result_model),
         true <- metadata_value(metadata, :job_id) == adoption.job.id,
         true <- metadata_value(metadata, :result_model) == adoption.job.result_model,
         true <-
           compact_digest(metadata_value(metadata, :artifact_sha256)) ==
             compact_digest(adoption.artifact_sha256) do
      :ok
    else
      false -> {:error, :adoption_rebound_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp artifact_sha256(%TrainingJob{provider: :mlx_lm}, manifest),
    do: get_in(manifest, ["fused_tree", "sha256"])

  defp artifact_sha256(%TrainingJob{provider: :trl}, manifest),
    do: manifest["payload_sha256"]

  defp job_sha256(job), do: digest(TrainingJob.dump(job))

  defp program_sha256(program) do
    {:ok, digest(Imp.Saving.dump(program))}
  rescue
    error -> {:error, {:adoption_program_not_portable, Exception.message(error)}}
  end

  defp program_model(program) do
    case Imp.ProgramAccess.lm(program) do
      %Imp.Clients.ReqLLM{model: model} -> model_value(model)
      %{model: model} -> model_value(model)
      _other -> {:error, :adoption_program_lm_identity_missing}
    end
  end

  defp model_value(value) when is_binary(value), do: {:ok, value}

  defp model_value(value) when is_map(value) do
    case Map.get(value, :id) || Map.get(value, "id") || Map.get(value, :model) ||
           Map.get(value, "model") do
      model when is_binary(model) -> {:ok, model}
      _missing -> {:error, :adoption_program_lm_identity_missing}
    end
  end

  defp model_value(_value), do: {:error, :adoption_program_lm_identity_missing}

  defp same_path?(left, right) when is_binary(left) and is_binary(right),
    do:
      Path.type(left) == :absolute and Path.type(right) == :absolute and
        Path.expand(left) == Path.expand(right)

  defp same_path?(_left, _right), do: false

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))

  defp metadata_value(_metadata, _key), do: nil

  defp compact_digest(value) when is_binary(value),
    do: value |> String.replace("sha256:", "") |> String.replace(":", "")

  defp compact_digest(_value), do: nil

  defp digest(value) do
    value
    |> ChatDataset.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secure_equal?(left, right) when is_binary(left) and byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
