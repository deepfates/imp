defmodule Imp.Clients.TRLProtocol do
  @moduledoc """
  Versioned data boundary between Imp's GRPO orchestrator and a TRL worker.

  This module does not execute Python or train a model. It defines the narrow,
  JSON-safe contract that a supervised worker around pinned TRL `v1.6.0` can
  implement. Every envelope is recursively allowlisted, canonically hashed,
  and identity-bound before it can be accepted. CPython `json.dumps` is the
  single numeric-spelling authority for cross-runtime envelope bytes; Imp uses
  `Imp.PyFloat.repr/1` for finite floats instead of Jason's Erlang spelling.

  A worker must durably spool the sealed update before mutation, publish its
  checkpoint and receipt as one atomic commit, and return the stored receipt
  for an exact idempotent replay. Reusing a step id with different content is
  always an error. If a worker cannot prove either non-acceptance or a durable
  receipt after a crash, the outcome remains ambiguous and Imp must not replay.
  """

  @schema_version 1
  @trl_version "1.6.0"
  @trl_revision "0dac440542c2ef9b575f56534f29f6fca1febe4a"
  @digest ~r/^sha256:[0-9a-f]{64}$/

  @type envelope :: %{required(String.t()) => term()}

  def schema_version, do: @schema_version

  def engine_identity,
    do: %{"name" => "trl", "version" => @trl_version, "revision" => @trl_revision}

  @doc "Builds and validates a session envelope."
  @spec session(map()) :: {:ok, envelope()} | {:error, term()}
  def session(attrs), do: build("imp_trl_grpo_session", attrs, &validate_session/1)

  @doc "Builds and validates one ordered GRPO update envelope."
  @spec update(map()) :: {:ok, envelope()} | {:error, term()}
  def update(attrs), do: build("imp_trl_grpo_update", attrs, &validate_update/1)

  @doc "Builds and validates an accepted-update receipt."
  @spec receipt(map()) :: {:ok, envelope()} | {:error, term()}
  def receipt(attrs), do: build("imp_trl_grpo_receipt", attrs, &validate_receipt/1)

  @doc "Builds and validates a durable trainer checkpoint manifest."
  @spec checkpoint(map()) :: {:ok, envelope()} | {:error, term()}
  def checkpoint(attrs), do: build("imp_trl_grpo_checkpoint", attrs, &validate_checkpoint/1)

  @doc "Builds and validates the final content-addressed artifact manifest."
  @spec artifact(map()) :: {:ok, envelope()} | {:error, term()}
  def artifact(attrs), do: build("imp_trl_grpo_artifact", attrs, &validate_artifact/1)

  def session!(attrs), do: unwrap!(session(attrs))
  def update!(attrs), do: unwrap!(update(attrs))
  def receipt!(attrs), do: unwrap!(receipt(attrs))
  def checkpoint!(attrs), do: unwrap!(checkpoint(attrs))
  def artifact!(attrs), do: unwrap!(artifact(attrs))

  @doc "Validates a sealed envelope, including its canonical payload digest."
  @spec validate(envelope()) :: :ok | {:error, term()}
  def validate(%{"type" => "imp_trl_grpo_session"} = value),
    do: verify(value, &validate_session/1)

  def validate(%{"type" => "imp_trl_grpo_update"} = value), do: verify(value, &validate_update/1)

  def validate(%{"type" => "imp_trl_grpo_receipt"} = value),
    do: verify(value, &validate_receipt/1)

  def validate(%{"type" => "imp_trl_grpo_checkpoint"} = value),
    do: verify(value, &validate_checkpoint/1)

  def validate(%{"type" => "imp_trl_grpo_artifact"} = value),
    do: verify(value, &validate_artifact/1)

  def validate(_value), do: {:error, :unknown_trl_protocol_envelope}

  @doc "Returns the canonical SHA-256 identity for a JSON-safe value."
  @spec digest(term()) :: String.t()
  def digest(value) do
    "sha256:" <>
      (value
       |> canonical_json()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end

  @doc "Encodes JSON with sorted keys and CPython-owned finite-float spelling."
  @spec canonical_json(term()) :: binary()
  def canonical_json(value), do: value |> canonical_iodata() |> IO.iodata_to_binary()

  defp build(type, attrs, validator) when is_map(attrs) do
    value =
      attrs
      |> stringify_keys()
      |> Map.merge(%{"type" => type, "schema_version" => @schema_version})
      |> then(&Map.put(&1, "payload_sha256", digest(&1)))

    case verify(value, validator) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  rescue
    error in ArgumentError -> {:error, {:invalid_trl_protocol_value, Exception.message(error)}}
  end

  defp build(_type, _attrs, _validator), do: {:error, :trl_protocol_attrs_must_be_a_map}

  defp verify(value, validator) do
    with :ok <- json_safe(value),
         :ok <- validator.(value),
         :ok <- verify_digest(value) do
      :ok
    end
  end

  defp verify_digest(%{"payload_sha256" => digest} = value) do
    expected = value |> Map.delete("payload_sha256") |> digest()
    if secure_equal?(digest, expected), do: :ok, else: {:error, :trl_protocol_digest_mismatch}
  end

  defp verify_digest(_value), do: {:error, :trl_protocol_digest_missing}

  defp validate_session(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(behavior_policy dataset engine optimizer payload_sha256 prompt_schedule rng schema_version session_id type)
           ),
         :ok <- fixed_header(value, "imp_trl_grpo_session"),
         :ok <- nonempty(value["session_id"], :session_id),
         :ok <- exact_engine(value["engine"]),
         :ok <- validate_dataset(value["dataset"]),
         :ok <- validate_schedule(value["prompt_schedule"]),
         :ok <- validate_behavior(value["behavior_policy"]),
         :ok <- validate_optimizer(value["optimizer"]),
         :ok <- validate_rng(value["rng"]) do
      :ok
    end
  end

  defp validate_update(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(behavior_policy groups idempotency_key optimizer payload_sha256 rng schema_version session_id session_payload_sha256 step_id trainer_step type)
           ),
         :ok <- fixed_header(value, "imp_trl_grpo_update"),
         :ok <- nonempty(value["session_id"], :session_id),
         :ok <- digest_value(value["session_payload_sha256"], :session_payload_sha256),
         :ok <- nonempty(value["step_id"], :step_id),
         true <-
           value["idempotency_key"] == value["step_id"] ||
             {:error, :trl_protocol_idempotency_key_mismatch},
         :ok <- nonnegative_integer(value["trainer_step"], :trainer_step),
         :ok <- validate_behavior(value["behavior_policy"]),
         :ok <- validate_optimizer_state(value["optimizer"]),
         :ok <- validate_rng(value["rng"]),
         :ok <- validate_groups(value["groups"]) do
      :ok
    end
  end

  defp validate_receipt(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(accepted_update_sha256 artifact checkpoint idempotency_key optimizer payload_sha256 rng schema_version session_id trainer_step type)
           ),
         :ok <- fixed_header(value, "imp_trl_grpo_receipt"),
         :ok <- nonempty(value["session_id"], :session_id),
         :ok <- nonempty(value["idempotency_key"], :idempotency_key),
         :ok <- digest_value(value["accepted_update_sha256"], :accepted_update_sha256),
         :ok <- positive_integer(value["trainer_step"], :trainer_step),
         :ok <- validate_transition(value["artifact"], :artifact),
         :ok <- validate_transition(value["optimizer"], :optimizer),
         :ok <- validate_transition(value["rng"], :rng),
         :ok <- validate_checkpoint_ref(value["checkpoint"]) do
      :ok
    end
  end

  defp validate_checkpoint(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(accepted_update_sha256s artifact_sha256 optimizer payload_sha256 rng schema_version session_id trainer_step type)
           ),
         :ok <- fixed_header(value, "imp_trl_grpo_checkpoint"),
         :ok <- nonempty(value["session_id"], :session_id),
         :ok <- nonnegative_integer(value["trainer_step"], :trainer_step),
         :ok <- digest_list(value["accepted_update_sha256s"], :accepted_update_sha256s),
         :ok <- digest_value(value["artifact_sha256"], :artifact_sha256),
         :ok <- validate_optimizer_state(value["optimizer"]),
         :ok <- validate_rng(value["rng"]) do
      :ok
    end
  end

  defp validate_artifact(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(base_model base_model_sha256 checkpoint_sha256 files payload_sha256 receipt_sha256s schema_version session_id trainer_step type)
           ),
         :ok <- fixed_header(value, "imp_trl_grpo_artifact"),
         :ok <- nonempty(value["session_id"], :session_id),
         :ok <- nonempty(value["base_model"], :base_model),
         :ok <- digest_value(value["base_model_sha256"], :base_model_sha256),
         :ok <- digest_value(value["checkpoint_sha256"], :checkpoint_sha256),
         :ok <- digest_list(value["receipt_sha256s"], :receipt_sha256s),
         :ok <- positive_integer(value["trainer_step"], :trainer_step),
         :ok <- validate_files(value["files"]) do
      :ok
    end
  end

  defp fixed_header(%{"type" => type, "schema_version" => @schema_version}, type), do: :ok
  defp fixed_header(_value, type), do: {:error, {:invalid_trl_protocol_header, type}}

  defp exact_engine(engine) do
    if engine == engine_identity(),
      do: :ok,
      else: {:error, :trl_protocol_engine_identity_mismatch}
  end

  defp validate_dataset(value) do
    with :ok <- exact_keys(value, ~w(ordered_train_row_sha256s train_sha256 validation_sha256)),
         :ok <- digest_value(value["train_sha256"], :train_sha256),
         :ok <- optional_digest(value["validation_sha256"], :validation_sha256),
         :ok <-
           nonempty_digest_list(value["ordered_train_row_sha256s"], :ordered_train_row_sha256s) do
      :ok
    end
  end

  defp validate_schedule(value) do
    with :ok <- exact_keys(value, ~w(selector steps)),
         true <- value["selector"] == "imp_grpo_v1" || {:error, :trl_protocol_selector_mismatch},
         true <- is_list(value["steps"]) || {:error, :trl_protocol_steps_must_be_a_list} do
      value["steps"]
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
        result =
          with :ok <- exact_keys(step, ~w(ordered_row_sha256s step)),
               true <- step["step"] == index || {:error, :trl_protocol_step_order_mismatch},
               :ok <- nonempty_digest_list(step["ordered_row_sha256s"], :ordered_row_sha256s) do
            :ok
          end

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
    end
  end

  defp validate_behavior(value) do
    with :ok <- exact_keys(value, ~w(artifact_sha256 model tokenizer_sha256)),
         :ok <- nonempty(value["model"], :model),
         :ok <- digest_value(value["artifact_sha256"], :artifact_sha256),
         :ok <- digest_value(value["tokenizer_sha256"], :tokenizer_sha256) do
      :ok
    end
  end

  defp validate_optimizer(value) do
    with :ok <- exact_keys(value, ~w(config_sha256 name num_generations)),
         true <- value["name"] == "grpo" || {:error, :trl_protocol_optimizer_mismatch},
         :ok <- digest_value(value["config_sha256"], :config_sha256),
         :ok <- positive_integer(value["num_generations"], :num_generations) do
      :ok
    end
  end

  defp validate_optimizer_state(value) do
    with :ok <- exact_keys(value, ~w(global_step state_sha256)),
         :ok <- nonnegative_integer(value["global_step"], :global_step),
         :ok <- digest_value(value["state_sha256"], :state_sha256) do
      :ok
    end
  end

  defp validate_rng(value) do
    with :ok <- exact_keys(value, ~w(algorithm state_sha256)),
         :ok <- nonempty(value["algorithm"], :rng_algorithm),
         :ok <- digest_value(value["state_sha256"], :rng_state_sha256) do
      :ok
    end
  end

  defp validate_groups(groups) when is_list(groups) and groups != [] do
    groups
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {group, index}, {:ok, ids} ->
      with :ok <- validate_group_keys(group),
           :ok <- nonempty(group["batch_id"], :batch_id),
           :ok <- unique_value(ids, group["batch_id"], :trl_protocol_duplicate_batch_id),
           true <-
             group["group_position"] == index || {:error, :trl_protocol_group_order_mismatch},
           :ok <- nonempty(group["group_id"], :group_id),
           :ok <- nonempty(group["predictor"], :predictor),
           :ok <- digest_value(group["prompt_sha256"], :prompt_sha256),
           :ok <- validate_prompt(group["prompt"], group["prompt_sha256"]),
           :ok <- validate_samples(group["samples"], group["prompt_sha256"]),
           :ok <- validate_group_source(group) do
        {:cont, {:ok, MapSet.put(ids, group["batch_id"])}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _ids} -> :ok
      error -> error
    end
  end

  defp validate_groups(_groups), do: {:error, :trl_protocol_groups_must_be_nonempty}

  defp validate_group_keys(group) do
    legacy = ~w(batch_id group_id group_position predictor prompt prompt_sha256 samples)
    source_bound = legacy ++ ~w(selection_step source_position source_row_sha256)
    actual = group |> Map.keys() |> Enum.sort()

    cond do
      actual == Enum.sort(source_bound) -> :ok
      actual == Enum.sort(legacy) -> :ok
      true -> {:error, {:trl_protocol_keys_mismatch, Enum.sort(source_bound), actual}}
    end
  end

  defp validate_group_source(%{
         "selection_step" => step,
         "source_position" => position,
         "source_row_sha256" => source
       }) do
    with :ok <- nonnegative_integer(step, :selection_step),
         :ok <- nonnegative_integer(position, :source_position),
         :ok <- digest_value(source, :source_row_sha256) do
      :ok
    end
  end

  defp validate_group_source(_legacy_group), do: :ok

  defp validate_samples(samples, prompt_sha256) when is_list(samples) and length(samples) > 1 do
    samples
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {sample, index}, :ok ->
      result =
        with :ok <-
               exact_keys(
                 sample,
                 ~w(behavior_logprobs completion completion_mask completion_sha256 completion_token_ids position prompt_mask prompt_sha256 prompt_token_ids reward)
               ),
             true <- sample["position"] == index || {:error, :trl_protocol_sample_order_mismatch},
             true <-
               sample["prompt_sha256"] == prompt_sha256 ||
                 {:error, :trl_protocol_prompt_identity_mismatch},
             :ok <- token_vector(sample["prompt_token_ids"], :prompt_token_ids),
             :ok <- mask_vector(sample["prompt_mask"], sample["prompt_token_ids"], :prompt_mask),
             :ok <- token_vector(sample["completion_token_ids"], :completion_token_ids),
             :ok <-
               mask_vector(
                 sample["completion_mask"],
                 sample["completion_token_ids"],
                 :completion_mask
               ),
             :ok <- logprob_vector(sample["behavior_logprobs"], sample["completion_token_ids"]),
             :ok <- completion_identity(sample["completion"], sample["completion_sha256"]),
             :ok <- digest_value(sample["completion_sha256"], :completion_sha256),
             :ok <- finite_number(sample["reward"], :reward) do
          :ok
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp validate_samples(_samples, _prompt_sha256),
    do: {:error, :trl_protocol_group_requires_multiple_completions}

  defp validate_prompt(messages, prompt_sha256) when is_list(messages) and messages != [] do
    result =
      Enum.reduce_while(messages, :ok, fn message, :ok ->
        with :ok <- exact_keys(message, ~w(content role)),
             :ok <- nonempty(message["role"], :message_role),
             true <-
               is_binary(message["content"]) || {:error, :trl_protocol_message_content_required} do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with :ok <- result,
         true <-
           digest(%{"messages" => messages}) == prompt_sha256 ||
             {:error, :trl_protocol_prompt_digest_mismatch} do
      :ok
    end
  end

  defp validate_prompt(_messages, _prompt_sha256),
    do: {:error, :trl_protocol_prompt_messages_required}

  defp completion_identity(completion, completion_sha256) when is_binary(completion) do
    if digest(%{"completion" => completion}) == completion_sha256,
      do: :ok,
      else: {:error, :trl_protocol_completion_digest_mismatch}
  end

  defp completion_identity(_completion, _completion_sha256),
    do: {:error, :trl_protocol_completion_text_required}

  defp validate_transition(value, name) do
    with :ok <- exact_keys(value, ~w(after_sha256 before_sha256)),
         :ok <- digest_value(value["before_sha256"], {name, :before_sha256}),
         :ok <- digest_value(value["after_sha256"], {name, :after_sha256}) do
      :ok
    end
  end

  defp validate_checkpoint_ref(value) do
    with :ok <- exact_keys(value, ~w(payload_sha256 path)),
         :ok <- nonempty(value["path"], :checkpoint_path),
         :ok <- digest_value(value["payload_sha256"], :checkpoint_payload_sha256) do
      :ok
    end
  end

  defp validate_files(files) when is_list(files) and files != [] do
    Enum.reduce_while(files, {:ok, MapSet.new()}, fn file, {:ok, paths} ->
      with :ok <- exact_keys(file, ~w(path sha256 size)),
           :ok <- safe_relative_path(file["path"]),
           :ok <- unique_value(paths, file["path"], :trl_protocol_duplicate_artifact_path),
           :ok <- digest_value(file["sha256"], :file_sha256),
           :ok <- nonnegative_integer(file["size"], :file_size) do
        {:cont, {:ok, MapSet.put(paths, file["path"])}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _paths} -> :ok
      error -> error
    end
  end

  defp validate_files(_files), do: {:error, :trl_protocol_artifact_files_must_be_nonempty}

  defp safe_relative_path(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path, "/artifact")

    if String.starts_with?(expanded, "/artifact/"),
      do: :ok,
      else: {:error, :trl_protocol_unsafe_artifact_path}
  end

  defp safe_relative_path(_path), do: {:error, :trl_protocol_unsafe_artifact_path}

  defp token_vector(values, name) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)),
      do: :ok,
      else: {:error, {:invalid_trl_protocol_tokens, name}}
  end

  defp token_vector(_values, name), do: {:error, {:invalid_trl_protocol_tokens, name}}

  defp mask_vector(mask, tokens, name) when is_list(mask) and length(mask) == length(tokens) do
    if Enum.all?(mask, &(&1 in [0, 1])),
      do: :ok,
      else: {:error, {:invalid_trl_protocol_mask, name}}
  end

  defp mask_vector(_mask, _tokens, name), do: {:error, {:invalid_trl_protocol_mask, name}}

  defp logprob_vector(values, tokens) when is_list(values) and length(values) == length(tokens) do
    if Enum.all?(values, &finite?/1),
      do: :ok,
      else: {:error, :invalid_trl_protocol_behavior_logprobs}
  end

  defp logprob_vector(_values, _tokens), do: {:error, :invalid_trl_protocol_behavior_logprobs}

  defp exact_keys(value, keys) when is_map(value) do
    actual = value |> Map.keys() |> Enum.sort()
    expected = Enum.sort(keys)

    if actual == expected,
      do: :ok,
      else: {:error, {:trl_protocol_keys_mismatch, expected, actual}}
  end

  defp exact_keys(_value, keys), do: {:error, {:trl_protocol_object_required, Enum.sort(keys)}}

  defp unique_value(values, value, reason) do
    if MapSet.member?(values, value), do: {:error, reason}, else: :ok
  end

  defp nonempty(value, _name) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty(_value, name), do: {:error, {:trl_protocol_nonempty_string_required, name}}

  defp digest_value(value, name) when is_binary(value) do
    if Regex.match?(@digest, value),
      do: :ok,
      else: {:error, {:trl_protocol_digest_required, name}}
  end

  defp digest_value(_value, name), do: {:error, {:trl_protocol_digest_required, name}}

  defp optional_digest(nil, _name), do: :ok
  defp optional_digest(value, name), do: digest_value(value, name)

  defp digest_list(values, name) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 =~ @digest)),
      do: :ok,
      else: {:error, {:trl_protocol_digest_list_required, name}}
  end

  defp digest_list(_values, name), do: {:error, {:trl_protocol_digest_list_required, name}}

  defp nonempty_digest_list([], name),
    do: {:error, {:trl_protocol_nonempty_digest_list_required, name}}

  defp nonempty_digest_list(values, name), do: digest_list(values, name)

  defp nonnegative_integer(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp nonnegative_integer(_value, name),
    do: {:error, {:trl_protocol_nonnegative_integer_required, name}}

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: :ok

  defp positive_integer(_value, name),
    do: {:error, {:trl_protocol_positive_integer_required, name}}

  defp finite_number(value, _name) when is_number(value) do
    if finite?(value), do: :ok, else: {:error, :trl_protocol_finite_number_required}
  end

  defp finite_number(_value, name), do: {:error, {:trl_protocol_finite_number_required, name}}

  defp finite?(value) when is_integer(value), do: true

  defp finite?(value) when is_float(value),
    do: value == value and value <= 1.7976931348623157e308 and value >= -1.7976931348623157e308

  defp finite?(_value), do: false

  defp json_safe(nil), do: :ok
  defp json_safe(value) when is_binary(value) or is_boolean(value) or is_integer(value), do: :ok
  defp json_safe(value) when is_float(value), do: finite_number(value, :json_value)
  defp json_safe(values) when is_list(values), do: reduce_safe(values)

  defp json_safe(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1),
      do: reduce_safe(Map.values(value)),
      else: {:error, :trl_protocol_string_keys_required}
  end

  defp json_safe(_value), do: {:error, :trl_protocol_json_value_required}

  defp reduce_safe(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case json_safe(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_atom(key) or is_binary(key) ->
        {to_string(key), stringify_keys(nested)}

      {key, _nested} ->
        raise ArgumentError, "protocol map key must be a string or atom, got: #{inspect(key)}"
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical_iodata(nil), do: "null"
  defp canonical_iodata(true), do: "true"
  defp canonical_iodata(false), do: "false"
  defp canonical_iodata(value) when is_binary(value), do: Jason.encode!(value)
  defp canonical_iodata(value) when is_integer(value), do: Integer.to_string(value)

  defp canonical_iodata(value) when is_float(value) do
    if finite?(value),
      do: Imp.PyFloat.repr(value),
      else: raise(ArgumentError, "non-finite JSON number")
  end

  defp canonical_iodata(values) when is_list(values),
    do: ["[", Enum.intersperse(Enum.map(values, &canonical_iodata/1), ","), "]"]

  defp canonical_iodata(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn
        {key, nested} when is_binary(key) ->
          [Jason.encode!(key), ":", canonical_iodata(nested)]

        {key, _nested} ->
          raise ArgumentError, "canonical JSON key must be a string, got: #{inspect(key)}"
      end)
      |> Enum.sort_by(&IO.iodata_to_binary/1)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical_iodata(value), do: raise(ArgumentError, "not a JSON value: #{inspect(value)}")

  defp secure_equal?(left, right) when is_binary(left) and byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, reason}),
    do: raise(ArgumentError, "invalid Imp↔TRL protocol envelope: #{inspect(reason)}")
end
