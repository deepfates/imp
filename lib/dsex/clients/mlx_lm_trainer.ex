defmodule DSEx.Clients.MLXLMTrainer do
  @moduledoc """
  Optional synchronous SFT backend for a pinned local MLX-LM model snapshot.

  The trainer ignores the deployment LM supplied to
  `DSEx.Clients.Trainer.finetune/4` and produces adapter artifacts only. It does
  not fuse or deploy them.

  MLX-LM is an external optional dependency, pinned to `0.31.3`. Model inputs
  are immutable Hugging Face snapshots: a remote repository name is recorded
  for provenance, but the command receives only a local directory whose final
  component is the configured 40-character revision.
  """

  @behaviour DSEx.Clients.Trainer

  alias DSEx.Clients.TrainingJob
  alias DSEx.Training.ChatDataset

  @mlx_lm_version "0.31.3"
  @default_model "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
  @default_revision "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"
  @artifact_files ["adapter_config.json", "adapters.safetensors"]
  @sha256 ~r/\A[0-9a-f]{40}\z/

  @enforce_keys [:model, :model_revision, :root]
  defstruct model: @default_model,
            model_revision: @default_revision,
            model_path: nil,
            root: nil,
            executable: "mlx_lm.lora",
            executable_args: [],
            runner: DSEx.ExternalCommand,
            signature: nil,
            adapter: DSEx.Adapter.Chat,
            timeout: 3_600_000,
            kill_grace_ms: 2_000,
            max_output_bytes: 32_768,
            validation_fraction: 0.1,
            stratify_by: [],
            seed: 0,
            iters: 216,
            batch_size: 1,
            grad_accumulation_steps: 4,
            learning_rate: 1.0e-4,
            num_layers: 8,
            max_seq_length: 512,
            save_every: 100,
            mask_prompt: true

  @type runner ::
          module() | (String.t(), [String.t()], keyword() -> {:ok, map()} | {:error, term()})

  @type t :: %__MODULE__{
          model: String.t(),
          model_revision: String.t(),
          model_path: String.t() | nil,
          root: String.t(),
          executable: String.t(),
          executable_args: [String.t()],
          runner: runner(),
          signature: DSEx.Signature.t() | nil,
          adapter: module(),
          timeout: pos_integer(),
          kill_grace_ms: non_neg_integer(),
          max_output_bytes: pos_integer(),
          validation_fraction: number(),
          stratify_by: [atom() | String.t()],
          seed: integer(),
          iters: pos_integer(),
          batch_size: pos_integer(),
          grad_accumulation_steps: pos_integer(),
          learning_rate: number(),
          num_layers: integer(),
          max_seq_length: pos_integer(),
          save_every: pos_integer(),
          mask_prompt: boolean()
        }

  @doc "Builds a local MLX-LM trainer. No executable or model is loaded until `finetune/4`."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "MLXLMTrainer.new/1 expects keyword options")

    root = Keyword.get(opts, :root, default_root())

    trainer =
      struct!(
        __MODULE__,
        opts
        |> Keyword.put_new(:model, @default_model)
        |> Keyword.put_new(:model_revision, @default_revision)
        |> Keyword.put(:root, root)
      )

    validate_trainer!(trainer)
  end

  @doc false
  def mlx_lm_version, do: @mlx_lm_version

  @doc false
  def default_model, do: {@default_model, @default_revision}

  @doc "Verifies and returns the durable manifest for a completed MLX-LM training job."
  @spec verify_job(TrainingJob.t()) :: {:ok, map()} | {:error, term()}
  def verify_job(
        %TrainingJob{provider: :mlx_lm, status: :succeeded, result_model: adapter_dir} = job
      )
      when is_binary(adapter_dir) do
    manifest_ref = job.metadata[:manifest] || job.metadata["manifest"]

    unless is_binary(manifest_ref),
      do: raise(ArgumentError, "MLX-LM job manifest path is missing")

    manifest_path = Path.expand(manifest_ref, adapter_dir)

    with {:ok, manifest} <- read_manifest(manifest_path),
         true <- manifest["status"] == "succeeded",
         :ok <- verify_artifact_hashes(adapter_dir, manifest["artifacts"]) do
      {:ok, manifest}
    else
      false -> {:error, :mlx_lm_training_not_succeeded}
      {:error, _reason} = error -> error
    end
  end

  def verify_job(%TrainingJob{}), do: {:error, :not_a_completed_mlx_lm_job}

  @impl true
  def supported_methods(_trainer), do: [:sft]

  @impl true
  def finetune(%__MODULE__{} = trainer, _deployment_lm, examples, opts) do
    with {:ok, call} <- call_config(trainer, opts),
         {:ok, model_path} <- pinned_model_path(trainer),
         {:ok, dataset} <-
           ChatDataset.build(examples, call.signature, call.adapter, dataset_opts(call)),
         {:ok, context} <- prepare_context(trainer, call, model_path, dataset),
         {:ok, job} <- execute_or_replay(trainer, call, context) do
      {:ok, job}
    end
  rescue
    error -> {:error, {:mlx_lm_training_failed, DSEx.Redaction.redact(Exception.message(error))}}
  catch
    kind, reason ->
      {:error, {:mlx_lm_training_failed, DSEx.Redaction.redact(inspect({kind, reason}))}}
  end

  defp call_config(trainer, opts) do
    allowed = [
      :method,
      :signature,
      :adapter,
      :validation_fraction,
      :stratify_by,
      :seed,
      :iters,
      :batch_size,
      :grad_accumulation_steps,
      :learning_rate,
      :num_layers,
      :max_seq_length,
      :save_every,
      :mask_prompt
    ]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end

    signature = Keyword.get(opts, :signature, trainer.signature)
    adapter = Keyword.get(opts, :adapter, trainer.adapter)

    if match?(%DSEx.Signature{}, signature) and is_atom(adapter) do
      {:ok,
       %{
         signature: signature,
         adapter: adapter,
         validation_fraction:
           Keyword.get(opts, :validation_fraction, trainer.validation_fraction),
         stratify_by: Keyword.get(opts, :stratify_by, trainer.stratify_by) |> List.wrap(),
         seed: Keyword.get(opts, :seed, trainer.seed),
         iters: Keyword.get(opts, :iters, trainer.iters),
         batch_size: Keyword.get(opts, :batch_size, trainer.batch_size),
         grad_accumulation_steps:
           Keyword.get(opts, :grad_accumulation_steps, trainer.grad_accumulation_steps),
         learning_rate: Keyword.get(opts, :learning_rate, trainer.learning_rate),
         num_layers: Keyword.get(opts, :num_layers, trainer.num_layers),
         max_seq_length: Keyword.get(opts, :max_seq_length, trainer.max_seq_length),
         save_every: Keyword.get(opts, :save_every, trainer.save_every),
         mask_prompt: Keyword.get(opts, :mask_prompt, trainer.mask_prompt)
       }
       |> validate_call_config()}
    else
      {:error, :mlx_lm_signature_and_adapter_required}
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_mlx_lm_options, Exception.message(error)}}
  end

  defp validate_call_config(call) do
    cond do
      not (is_number(call.validation_fraction) and call.validation_fraction >= 0 and
               call.validation_fraction < 1) ->
        raise ArgumentError, "validation_fraction must be in [0, 1)"

      not is_integer(call.seed) ->
        raise ArgumentError, "seed must be an integer"

      not positive_integer?(call.iters) ->
        raise ArgumentError, "iters must be positive"

      not positive_integer?(call.batch_size) ->
        raise ArgumentError, "batch_size must be positive"

      not positive_integer?(call.grad_accumulation_steps) ->
        raise ArgumentError, "grad_accumulation_steps must be positive"

      not (is_number(call.learning_rate) and call.learning_rate > 0) ->
        raise ArgumentError, "learning_rate must be positive"

      not (is_integer(call.num_layers) and call.num_layers != 0 and call.num_layers >= -1) ->
        raise ArgumentError, "num_layers must be -1 or positive"

      not positive_integer?(call.max_seq_length) ->
        raise ArgumentError, "max_seq_length must be positive"

      not positive_integer?(call.save_every) ->
        raise ArgumentError, "save_every must be positive"

      not is_boolean(call.mask_prompt) ->
        raise ArgumentError, "mask_prompt must be boolean"

      true ->
        call
    end
  end

  defp dataset_opts(call),
    do: [
      validation_fraction: call.validation_fraction,
      stratify_by: call.stratify_by,
      seed: call.seed
    ]

  defp pinned_model_path(%__MODULE__{} = trainer) do
    path = trainer.model_path || hugging_face_snapshot_path(trainer.model, trainer.model_revision)
    expanded = Path.expand(path)

    cond do
      not File.dir?(expanded) ->
        {:error, {:mlx_lm_model_snapshot_missing, expanded}}

      Path.basename(expanded) != trainer.model_revision ->
        {:error, {:mlx_lm_model_revision_mismatch, expanded}}

      true ->
        {:ok, expanded}
    end
  end

  defp prepare_context(trainer, call, model_path, dataset) do
    spec = %{
      "adapter" => Atom.to_string(call.adapter),
      "dataset_sha256" => dataset.dataset_sha256,
      "mlx_lm_version" => @mlx_lm_version,
      "model" => trainer.model,
      "model_path" => model_path,
      "model_revision" => trainer.model_revision,
      "training" => training_spec(call)
    }

    run_id = sha256(ChatDataset.canonical_json(spec))
    run_dir = Path.join(Path.expand(trainer.root), chunk_hash(run_id, "-"))

    {:ok,
     %{
       spec: spec,
       run_id: run_id,
       run_dir: run_dir,
       data_dir: Path.join(run_dir, "data"),
       adapter_dir: Path.join(run_dir, "adapter"),
       manifest_path: Path.join(run_dir, "manifest.json"),
       lock_path: Path.join(run_dir, ".lock"),
       dataset: dataset
     }}
  end

  defp execute_or_replay(trainer, call, context) do
    case load_existing(context) do
      {:ok, %{"status" => "succeeded"} = manifest} -> completed_job(context, manifest)
      {:error, _reason} = error -> error
      {:ok, manifest} -> with_lock(context, fn -> execute(trainer, call, context, manifest) end)
      :missing -> with_lock(context, fn -> initialize_and_execute(trainer, call, context) end)
    end
  end

  defp initialize_and_execute(trainer, call, context) do
    File.mkdir_p!(context.data_dir)
    File.mkdir_p!(context.adapter_dir)
    atomic_write!(Path.join(context.data_dir, "train.jsonl"), context.dataset.train_jsonl)

    if context.dataset.valid_count > 0 do
      atomic_write!(Path.join(context.data_dir, "valid.jsonl"), context.dataset.valid_jsonl)
    end

    manifest = base_manifest(context, "prepared")
    write_manifest!(context.manifest_path, manifest)
    execute(trainer, call, context, manifest)
  end

  defp execute(trainer, call, context, manifest) do
    with :ok <- verify_dataset_files(context, manifest),
         {:ok, resume_path} <- resume_path(context, manifest) do
      argv = command_argv(context, call, resume_path)
      running = manifest |> Map.put("status", "running") |> Map.put("argv", argv)
      write_manifest!(context.manifest_path, running)

      case run_command(trainer, argv, context.run_dir) do
        {:ok, %{exit_status: 0} = result} -> finish_success(trainer, context, running, result)
        {:ok, result} -> finish_failure(context, running, {:unexpected_runner_result, result})
        {:error, reason} -> finish_failure(context, running, reason)
        other -> finish_failure(context, running, {:invalid_runner_result, other})
      end
    end
  end

  defp finish_success(trainer, context, manifest, result) do
    with {:ok, artifacts} <- valid_artifacts(context.adapter_dir, context.spec["model_path"]) do
      succeeded =
        manifest
        |> Map.put("status", "succeeded")
        |> Map.put("artifacts", artifacts)
        |> Map.put("command", command_summary(result))

      write_manifest!(context.manifest_path, succeeded)
      completed_job(context, succeeded, trainer)
    else
      {:error, reason} -> finish_failure(context, manifest, reason)
    end
  end

  defp finish_failure(context, manifest, reason) do
    checkpoint = checkpoint_if_valid(context.adapter_dir, context.spec["model_path"])

    failed =
      manifest
      |> Map.put("status", "failed")
      |> Map.put("error", DSEx.Redaction.redact(inspect(reason)))
      |> maybe_put("checkpoint", checkpoint)

    write_manifest!(context.manifest_path, failed)
    {:error, {:mlx_lm_command_failed, redact_term(reason)}}
  end

  defp load_existing(context) do
    if File.exists?(context.manifest_path) do
      with {:ok, manifest} <- read_manifest(context.manifest_path),
           true <- manifest["run_id"] == context.run_id,
           true <- manifest["spec"] == context.spec do
        {:ok, manifest}
      else
        false -> {:error, :mlx_lm_manifest_identity_mismatch}
        {:error, _reason} = error -> error
      end
    else
      :missing
    end
  end

  defp completed_job(context, manifest, trainer \\ nil) do
    with :ok <- verify_dataset_files(context, manifest),
         :ok <- verify_artifact_hashes(context.adapter_dir, manifest["artifacts"]) do
      trainer =
        trainer ||
          %__MODULE__{
            model: context.spec["model"],
            model_revision: context.spec["model_revision"],
            root: Path.dirname(context.run_dir)
          }

      {:ok,
       TrainingJob.new(%{
         id: "mlx-" <> binary_part(context.run_id, 0, 20),
         provider: :mlx_lm,
         model: trainer.model <> "@" <> trainer.model_revision,
         status: :succeeded,
         result_model: context.adapter_dir,
         training_data: [context.dataset.train_count, context.dataset.valid_count],
         idempotency_key: "dsex-mlx:" <> chunk_hash(context.run_id),
         metadata: %{
           manifest: "../manifest.json",
           dataset_sha256: chunk_hash(context.dataset.dataset_sha256),
           mlx_lm_version: @mlx_lm_version,
           model_revision: chunk_hash(trainer.model_revision),
           artifact_sha256:
             Map.new(manifest["artifacts"], fn {name, attrs} ->
               {name, chunk_hash(attrs["sha256"])}
             end)
         }
       })}
    end
  end

  defp resume_path(context, manifest) do
    checkpoint = manifest["checkpoint"]

    cond do
      is_map(checkpoint) ->
        case verify_artifact_hashes(context.adapter_dir, checkpoint) do
          :ok -> {:ok, Path.join(context.adapter_dir, "adapters.safetensors")}
          {:error, _reason} -> {:error, :mlx_lm_checkpoint_tampered}
        end

      File.exists?(Path.join(context.adapter_dir, "adapters.safetensors")) ->
        case valid_artifacts(context.adapter_dir, context.spec["model_path"]) do
          {:ok, _artifacts} -> {:ok, Path.join(context.adapter_dir, "adapters.safetensors")}
          {:error, _reason} -> {:error, :invalid_mlx_lm_resume_checkpoint}
        end

      true ->
        {:ok, nil}
    end
  end

  defp command_argv(context, call, resume_path) do
    [
      "--model",
      context.spec["model_path"],
      "--train",
      "--data",
      context.data_dir,
      "--adapter-path",
      context.adapter_dir,
      "--fine-tune-type",
      "lora",
      "--iters",
      Integer.to_string(call.iters),
      "--batch-size",
      Integer.to_string(call.batch_size),
      "--grad-accumulation-steps",
      Integer.to_string(call.grad_accumulation_steps),
      "--learning-rate",
      to_string(call.learning_rate),
      "--num-layers",
      Integer.to_string(call.num_layers),
      "--max-seq-length",
      Integer.to_string(call.max_seq_length),
      "--save-every",
      Integer.to_string(call.save_every),
      "--seed",
      Integer.to_string(call.seed)
    ]
    |> maybe_append(call.mask_prompt, ["--mask-prompt"])
    |> maybe_append(is_binary(resume_path), ["--resume-adapter-file", resume_path])
  end

  defp run_command(trainer, argv, cd) do
    opts = [
      timeout: trainer.timeout,
      kill_grace_ms: trainer.kill_grace_ms,
      max_output_bytes: trainer.max_output_bytes,
      cd: cd
    ]

    case trainer.runner do
      runner when is_function(runner, 3) ->
        runner.(trainer.executable, trainer.executable_args ++ argv, opts)

      runner when is_atom(runner) ->
        runner.run(trainer.executable, trainer.executable_args ++ argv, opts)
    end
  end

  defp valid_artifacts(adapter_dir, expected_model_path) do
    paths = Map.new(@artifact_files, &{&1, Path.join(adapter_dir, &1)})

    with true <-
           Enum.all?(paths, fn {_name, path} ->
             File.regular?(path) and File.stat!(path).size > 0
           end),
         {:ok, config} <- paths["adapter_config.json"] |> File.read!() |> Jason.decode(),
         true <- config["model"] == expected_model_path,
         true <- config["fine_tune_type"] == "lora" do
      {:ok, Map.new(paths, fn {name, path} -> {name, file_attrs(path)} end)}
    else
      false -> {:error, :mlx_lm_adapter_artifact_missing_or_invalid}
      {:error, _reason} -> {:error, :mlx_lm_adapter_config_invalid}
    end
  rescue
    File.Error -> {:error, :mlx_lm_adapter_artifact_missing_or_invalid}
  end

  defp checkpoint_if_valid(adapter_dir, expected_model_path) do
    case valid_artifacts(adapter_dir, expected_model_path) do
      {:ok, artifacts} -> artifacts
      {:error, _reason} -> nil
    end
  end

  defp verify_dataset_files(context, manifest) do
    expected = manifest["dataset"] || %{}

    entries = %{
      "train.jsonl" => {Path.join(context.data_dir, "train.jsonl"), expected["train_sha256"]}
    }

    entries =
      if expected["valid_count"] > 0 do
        Map.put(
          entries,
          "valid.jsonl",
          {Path.join(context.data_dir, "valid.jsonl"), expected["valid_sha256"]}
        )
      else
        entries
      end

    verify_hashes(entries, :mlx_lm_dataset_tampered)
  end

  defp verify_artifact_hashes(_adapter_dir, artifacts) when not is_map(artifacts),
    do: {:error, :mlx_lm_artifact_manifest_missing}

  defp verify_artifact_hashes(adapter_dir, artifacts) do
    entries =
      Map.new(artifacts, fn {name, attrs} ->
        {name, {Path.join(adapter_dir, name), attrs["sha256"]}}
      end)

    verify_hashes(entries, :mlx_lm_adapter_artifact_tampered)
  end

  defp verify_hashes(entries, error) do
    if Enum.all?(entries, fn {_name, {path, expected}} ->
         is_binary(expected) and File.regular?(path) and sha256(File.read!(path)) == expected
       end),
       do: :ok,
       else: {:error, error}
  rescue
    File.Error -> {:error, error}
  end

  defp base_manifest(context, status) do
    %{
      "artifact_type" => "dsex_mlx_lm_sft_run",
      "schema_version" => 1,
      "run_id" => context.run_id,
      "status" => status,
      "spec" => context.spec,
      "dataset" => %{
        "dataset_sha256" => context.dataset.dataset_sha256,
        "train_count" => context.dataset.train_count,
        "train_sha256" => context.dataset.train_sha256,
        "valid_count" => context.dataset.valid_count,
        "valid_sha256" => context.dataset.valid_sha256
      }
    }
  end

  defp training_spec(call) do
    %{
      "batch_size" => call.batch_size,
      "grad_accumulation_steps" => call.grad_accumulation_steps,
      "iters" => call.iters,
      "learning_rate" => call.learning_rate,
      "mask_prompt" => call.mask_prompt,
      "max_seq_length" => call.max_seq_length,
      "num_layers" => call.num_layers,
      "save_every" => call.save_every,
      "seed" => call.seed,
      "stratify_by" => Enum.map(call.stratify_by, &to_string/1),
      "validation_fraction" => call.validation_fraction
    }
  end

  defp command_summary(result) do
    %{
      "duration_ms" => Map.get(result, :duration_ms),
      "exit_status" => Map.get(result, :exit_status),
      "output" => result |> Map.get(:output, "") |> DSEx.Redaction.redact()
    }
  end

  defp write_manifest!(path, payload) do
    wrapper = %{
      "payload" => payload,
      "payload_sha256" => sha256(ChatDataset.canonical_json(payload))
    }

    atomic_write!(path, ChatDataset.canonical_json(wrapper) <> "\n")
  end

  defp read_manifest(path) do
    with {:ok, decoded} <- path |> File.read!() |> Jason.decode(),
         %{"payload" => payload, "payload_sha256" => expected} <- decoded,
         true <-
           is_binary(expected) and
             hash_equal?(expected, sha256(ChatDataset.canonical_json(payload))) do
      {:ok, payload}
    else
      false -> {:error, :mlx_lm_manifest_tampered}
      _other -> {:error, :invalid_mlx_lm_manifest}
    end
  rescue
    File.Error -> {:error, :invalid_mlx_lm_manifest}
  end

  defp with_lock(context, fun) do
    File.mkdir_p!(context.run_dir)

    case File.open(context.lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          fun.()
        after
          File.close(io)
          File.rm(context.lock_path)
        end

      {:error, :eexist} ->
        {:error, :mlx_lm_run_in_progress}

      {:error, reason} ->
        {:error, {:mlx_lm_lock_failed, reason}}
    end
  end

  defp atomic_write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, contents, [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp validate_trainer!(trainer) do
    cond do
      not (is_binary(trainer.model) and trainer.model != "") ->
        raise ArgumentError, "model must be a repository id"

      not (is_binary(trainer.model_revision) and Regex.match?(@sha256, trainer.model_revision)) ->
        raise ArgumentError, "model_revision must be a 40-character lowercase commit hash"

      not (is_nil(trainer.model_path) or is_binary(trainer.model_path)) ->
        raise ArgumentError, "model_path must be nil or a path"

      not (is_binary(trainer.root) and trainer.root != "") ->
        raise ArgumentError, "root must be a path"

      not (is_binary(trainer.executable) and trainer.executable != "") ->
        raise ArgumentError, "executable must be a command name or path"

      not (is_list(trainer.executable_args) and
               Enum.all?(
                 trainer.executable_args,
                 &(is_binary(&1) and not String.contains?(&1, <<0>>))
               )) ->
        raise ArgumentError, "executable_args must be a list of argv strings"

      not valid_runner?(trainer.runner) ->
        raise ArgumentError, "runner must be a module exporting run/3 or an arity-3 function"

      not positive_integer?(trainer.timeout) ->
        raise ArgumentError, "timeout must be positive"

      not (is_integer(trainer.kill_grace_ms) and trainer.kill_grace_ms >= 0) ->
        raise ArgumentError, "kill_grace_ms must be non-negative"

      not positive_integer?(trainer.max_output_bytes) ->
        raise ArgumentError, "max_output_bytes must be positive"

      true ->
        trainer
    end
  end

  defp valid_runner?(runner) when is_function(runner, 3), do: true

  defp valid_runner?(runner) when is_atom(runner),
    do: Code.ensure_loaded?(runner) and function_exported?(runner, :run, 3)

  defp valid_runner?(_runner), do: false

  defp hugging_face_snapshot_path(model, revision) do
    encoded = String.replace(model, "/", "--")

    Path.join([
      System.user_home!(),
      ".cache",
      "huggingface",
      "hub",
      "models--#{encoded}",
      "snapshots",
      revision
    ])
  end

  defp default_root, do: Path.join([System.user_home!(), ".cache", "dsex", "mlx_lm", "sft"])

  defp file_attrs(path),
    do: %{"bytes" => File.stat!(path).size, "sha256" => sha256(File.read!(path))}

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp hash_equal?(left, right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp chunk_hash(hash, separator \\ ":"),
    do:
      hash |> String.graphemes() |> Enum.chunk_every(8) |> Enum.map_join(separator, &Enum.join/1)

  defp redact_term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&redact_term/1) |> List.to_tuple()

  defp redact_term(value), do: DSEx.Redaction.redact(value)

  defp maybe_append(list, true, suffix), do: list ++ suffix
  defp maybe_append(list, false, _suffix), do: list
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
