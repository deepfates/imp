defmodule Imp.Clients.TRLArtifact do
  @moduledoc "Content verification for artifacts produced through the Imp↔TRL protocol."

  alias Imp.Clients.{TrainingJob, TRLProtocol}

  @manifest "imp-trl-artifact.json"

  @doc "Verifies a completed TRL training job and every file in its artifact manifest."
  def verify_job(%TrainingJob{provider: :trl, status: :succeeded} = job) do
    expected = Map.get(job.metadata, :artifact_sha256, Map.get(job.metadata, "artifact_sha256"))

    with true <- is_binary(job.result_model) || {:error, :trl_artifact_path_missing},
         true <- is_binary(expected) || {:error, :trl_artifact_identity_missing},
         {:ok, manifest} <- verify(job.result_model, expected),
         true <- manifest["session_id"] == job.id || {:error, :trl_artifact_session_mismatch},
         true <-
           manifest["base_model"] == job.model || {:error, :trl_artifact_base_model_mismatch} do
      {:ok, manifest}
    end
  end

  def verify_job(%TrainingJob{provider: :trl}), do: {:error, :trl_training_job_not_succeeded}
  def verify_job(%TrainingJob{}), do: {:error, :not_a_trl_training_job}

  @doc "Verifies a TRL artifact directory against its expected content identity."
  def verify(path, expected_sha256) when is_binary(path) and is_binary(expected_sha256) do
    root = Path.expand(path)
    manifest_path = Path.join(root, @manifest)

    with true <- File.dir?(root) || {:error, :trl_artifact_directory_missing},
         {:ok, encoded} <- read_file(manifest_path, :trl_artifact_manifest_missing),
         {:ok, manifest} <- decode_json(encoded, :trl_artifact_manifest_invalid),
         :ok <- TRLProtocol.validate(manifest),
         true <-
           secure_equal?(manifest["payload_sha256"], expected_sha256) ||
             {:error, :trl_artifact_identity_mismatch},
         :ok <- verify_inventory(root, manifest["files"]),
         :ok <- verify_files(root, manifest["files"]),
         {:ok, checkpoint} <- verify_checkpoint(root, manifest),
         {:ok, update_sha256s} <- verify_updates(root, manifest),
         true <-
           checkpoint["accepted_update_sha256s"] == update_sha256s ||
             {:error, :trl_artifact_checkpoint_update_mismatch},
         :ok <- verify_receipts(root, manifest, update_sha256s) do
      {:ok, manifest}
    end
  end

  def verify(_path, _expected_sha256), do: {:error, :invalid_trl_artifact_verification}

  defp verify_inventory(root, files) do
    expected = [@manifest | Enum.map(files, & &1["path"])] |> Enum.sort()

    case inventory(root, root) do
      {:ok, actual} ->
        actual = Enum.sort(actual)

        if actual == expected,
          do: :ok,
          else: {:error, {:trl_artifact_inventory_mismatch, expected, actual}}

      {:error, _reason} = error ->
        error
    end
  end

  defp inventory(root, directory) do
    directory
    |> File.ls()
    |> case do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, paths} ->
          path = Path.join(directory, entry)

          case File.lstat(path) do
            {:ok, %{type: :regular}} ->
              {:cont, {:ok, paths ++ [Path.relative_to(path, root)]}}

            {:ok, %{type: :directory}} ->
              case inventory(root, path) do
                {:ok, nested} -> {:cont, {:ok, paths ++ nested}}
                {:error, _reason} = error -> {:halt, error}
              end

            {:ok, %{type: type}} ->
              {:halt,
               {:error, {:trl_artifact_unsupported_file_type, Path.relative_to(path, root), type}}}

            {:error, reason} ->
              {:halt,
               {:error, {:trl_artifact_inventory_failed, Path.relative_to(path, root), reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:trl_artifact_inventory_failed, Path.relative_to(directory, root), reason}}
    end
  end

  defp verify_files(root, files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      path = Path.expand(file["path"], root)

      result =
        with true <- inside?(root, path) || {:error, :trl_artifact_path_escape},
             {:ok, contents} <- read_file(path, {:trl_artifact_file_missing, file["path"]}),
             true <-
               byte_size(contents) == file["size"] ||
                 {:error, {:trl_artifact_size_mismatch, file["path"]}},
             true <-
               secure_equal?(raw_digest(contents), file["sha256"]) ||
                 {:error, {:trl_artifact_file_digest_mismatch, file["path"]}} do
          :ok
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp verify_checkpoint(root, manifest) do
    path = Path.join(root, "trainer-checkpoint.json")

    with {:ok, encoded} <- read_file(path, :trl_artifact_checkpoint_missing),
         {:ok, checkpoint} <- decode_json(encoded, :trl_artifact_checkpoint_invalid),
         :ok <- TRLProtocol.validate(checkpoint),
         true <-
           secure_equal?(checkpoint["payload_sha256"], manifest["checkpoint_sha256"]) ||
             {:error, :trl_artifact_checkpoint_identity_mismatch},
         true <-
           checkpoint["session_id"] == manifest["session_id"] ||
             {:error, :trl_artifact_checkpoint_session_mismatch},
         true <-
           checkpoint["trainer_step"] == manifest["trainer_step"] ||
             {:error, :trl_artifact_checkpoint_step_mismatch} do
      {:ok, checkpoint}
    end
  end

  defp verify_updates(root, manifest) do
    1..manifest["trainer_step"]
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, identities} ->
      path = Path.join(root, "update-#{step}.json")

      with {:ok, encoded} <- read_file(path, {:trl_artifact_update_missing, step}),
           {:ok, update} <- decode_json(encoded, {:trl_artifact_update_invalid, step}),
           :ok <- TRLProtocol.validate(update),
           true <-
             update["session_id"] == manifest["session_id"] ||
               {:error, {:trl_artifact_update_session_mismatch, step}},
           true <-
             update["trainer_step"] == step - 1 ||
               {:error, {:trl_artifact_update_step_mismatch, step}} do
        {:cont, {:ok, identities ++ [update["payload_sha256"]]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_receipts(root, manifest, update_sha256s) do
    expected = manifest["receipt_sha256s"]

    actual =
      1..manifest["trainer_step"]
      |> Enum.reduce_while({:ok, {[], []}}, fn step, {:ok, {identities, accepted_updates}} ->
        path = Path.join(root, "receipt-#{step}.json")

        with {:ok, encoded} <- read_file(path, {:trl_artifact_receipt_missing, step}),
             {:ok, receipt} <- decode_json(encoded, {:trl_artifact_receipt_invalid, step}),
             :ok <- TRLProtocol.validate(receipt),
             true <-
               receipt["session_id"] == manifest["session_id"] ||
                 {:error, {:trl_artifact_receipt_session_mismatch, step}},
             true <-
               receipt["trainer_step"] == step ||
                 {:error, {:trl_artifact_receipt_step_mismatch, step}} do
          {:cont,
           {:ok,
            {identities ++ [receipt["payload_sha256"]],
             accepted_updates ++ [receipt["accepted_update_sha256"]]}}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case actual do
      {:ok, {^expected, ^update_sha256s}} ->
        :ok

      {:ok, {receipt_ids, _updates}} when receipt_ids != expected ->
        {:error, :trl_artifact_receipt_identity_mismatch}

      {:ok, {_receipt_ids, _updates}} ->
        {:error, :trl_artifact_receipt_update_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_json(encoded, reason) do
    case Jason.decode(encoded) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp read_file(path, reason) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, _file_reason} -> {:error, reason}
    end
  end

  defp inside?(root, path), do: path != root and String.starts_with?(path, root <> "/")

  defp raw_digest(contents) do
    "sha256:" <>
      (contents
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  defp secure_equal?(left, right) when is_binary(left) and byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
