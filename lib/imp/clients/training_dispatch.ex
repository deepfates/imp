defmodule Imp.Clients.TrainingDispatch do
  @moduledoc false

  alias Imp.Clients.{Trainer, TrainingJob}

  @artifact_type "imp_training_dispatch_journal"
  @schema_version 1

  @doc false
  def run(provider, lm, examples, opts, path)
      when is_list(examples) and is_list(opts) and is_binary(path) do
    lock = {__MODULE__, Path.expand(path)}

    :global.trans({lock, self()}, fn ->
      run_locked(provider, lm, examples, opts, path)
    end)
  rescue
    error -> {:error, {:training_dispatch_journal_failed, safe_message(error)}}
  end

  defp run_locked(provider, lm, examples, opts, path) do
    {observer, opts} = Keyword.pop(opts, :dispatch_observer)
    intent = intent(provider, lm, examples, opts)

    journal =
      if File.regular?(path) do
        load!(path)
      else
        save!(path, :prepared, intent, nil)
        notify(observer, :prepared, intent)
        load!(path)
      end

    with :ok <- verify_identity(journal, intent) do
      resume(journal, provider, lm, examples, opts, path, observer)
    end
  end

  @doc false
  def prepare!(provider, lm, examples, opts, path) do
    prepared = intent(provider, lm, examples, opts)
    save!(path, :prepared, prepared, nil)
    prepared.dispatch_id
  end

  @doc false
  def load!(path) when is_binary(path) do
    case path |> File.read!() |> Jason.decode!() do
      %{
        "artifact_type" => @artifact_type,
        "schema_version" => @schema_version,
        "payload" => payload,
        "payload_sha256" => digest
      } ->
        unless is_binary(digest) and secure_equal?(digest, checksum(payload)) do
          raise ArgumentError, "training dispatch journal checksum mismatch"
        end

        load_payload!(payload)

      _other ->
        raise ArgumentError, "invalid training dispatch journal"
    end
  end

  defp resume(%{phase: :prepared} = journal, provider, lm, examples, opts, path, observer) do
    save!(path, :dispatching, journal.intent, nil)
    submit(provider, lm, examples, opts, journal.intent, path, observer)
  end

  defp resume(
         %{phase: :dispatching} = journal,
         provider,
         lm,
         examples,
         opts,
         path,
         observer
       ) do
    case Trainer.reconcile_finetune(provider, journal.intent.dispatch_id) do
      {:ok, %TrainingJob{} = job} ->
        validate_and_commit(path, journal.intent, job, observer)

      {:error, :training_job_not_found} ->
        submit(provider, lm, examples, opts, journal.intent, path, observer)

      {:error, {:training_callback_not_supported, :reconcile_finetune}} ->
        {:error,
         {:training_dispatch_ambiguous, journal.intent.dispatch_id, :reconciliation_not_supported}}

      {:error, reason} ->
        {:error, {:training_dispatch_reconciliation_failed, journal.intent.dispatch_id, reason}}
    end
  end

  defp resume(
         %{phase: :committed, job: job},
         provider,
         _lm,
         _examples,
         _opts,
         _path,
         _observer
       ) do
    restore_committed(job, provider)
  end

  defp submit(provider, lm, examples, opts, intent, path, observer) do
    provider_opts = Keyword.put(opts, :idempotency_key, intent.dispatch_id)

    case Trainer.finetune_direct(provider, lm, examples, provider_opts) do
      {:ok, %TrainingJob{} = job} -> validate_and_commit(path, intent, job, observer)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_and_commit(path, intent, job, observer) do
    with :ok <- validate_job_identity(job, intent),
         {:ok, checkpoint} <- safe_job_checkpoint(job) do
      commit(path, intent, job, checkpoint, observer)
    end
  end

  defp commit(path, intent, job, checkpoint, observer) do
    save!(path, :committed, intent, checkpoint)
    notify(observer, :committed, intent)
    {:ok, job}
  end

  defp intent(provider, lm, examples, opts) do
    semantic =
      semantic_identity(%{
        provider: provider,
        model: lm,
        examples: Enum.map(examples, &Imp.Example.to_map/1),
        opts: Keyword.delete(opts, :idempotency_key)
      })

    identity_digest = digest_term(semantic)

    dispatch_id =
      "imp-training:" <>
        digest_term({identity_digest, Keyword.get(opts, :idempotency_key, :generated)})

    %{
      dispatch_id: dispatch_id,
      identity_digest: identity_digest,
      provider: semantic_identity(provider),
      model: semantic_identity(lm),
      method: Keyword.get(opts, :method, :sft)
    }
  end

  defp save!(path, phase, intent, job) do
    payload = %{
      "phase" => Atom.to_string(phase),
      "intent" => %{
        "dispatch_id" => intent.dispatch_id,
        "identity_digest" => intent.identity_digest,
        "provider" => Imp.Redaction.redact(intent.provider),
        "model" => Imp.Redaction.redact(intent.model),
        "method" => to_string(intent.method)
      },
      "job" => job
    }

    artifact = %{
      "artifact_type" => @artifact_type,
      "schema_version" => @schema_version,
      "payload_sha256" => checksum(payload),
      "payload" => payload
    }

    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
      :ok
    after
      File.rm(temporary)
    end
  end

  defp load_payload!(%{"phase" => phase, "intent" => raw_intent, "job" => raw_job}) do
    intent = %{
      dispatch_id: required_binary!(raw_intent, "dispatch_id"),
      identity_digest: required_binary!(raw_intent, "identity_digest"),
      provider: raw_intent["provider"],
      model: raw_intent["model"],
      method: load_method(raw_intent["method"])
    }

    case phase do
      "prepared" -> %{phase: :prepared, intent: intent, job: nil}
      "dispatching" -> %{phase: :dispatching, intent: intent, job: nil}
      "committed" -> %{phase: :committed, intent: intent, job: TrainingJob.load!(raw_job)}
      _other -> raise ArgumentError, "invalid training dispatch journal phase"
    end
  end

  defp load_payload!(_payload), do: raise(ArgumentError, "invalid training dispatch payload")

  defp verify_identity(journal, intent) do
    saved = journal.intent

    if saved.identity_digest == intent.identity_digest and saved.dispatch_id == intent.dispatch_id do
      :ok
    else
      {:error, :training_dispatch_identity_mismatch}
    end
  end

  defp restore_committed(%TrainingJob{} = job, %{__struct__: Imp.Clients.HTTPTrainer} = trainer) do
    {:ok, restore_http_runtime(job, trainer)}
  end

  defp restore_committed(%TrainingJob{} = saved_job, provider) do
    case Trainer.reconcile_finetune(provider, saved_job.idempotency_key) do
      {:ok, %TrainingJob{} = reconciled} ->
        with :ok <- validate_job_identity(reconciled, %{dispatch_id: saved_job.idempotency_key}),
             :ok <- validate_same_job(saved_job, reconciled) do
          {:ok, reconciled}
        end

      {:error, {:training_callback_not_supported, :reconcile_finetune}} ->
        {:error, {:training_dispatch_runtime_restoration_unavailable, saved_job.idempotency_key}}

      {:error, reason} ->
        {:error,
         {:training_dispatch_runtime_restoration_failed, saved_job.idempotency_key, reason}}
    end
  end

  defp restore_http_runtime(%TrainingJob{} = job, trainer) do
    %{
      job
      | transport: trainer.transport,
        api_key: trainer.api_key,
        max_attempts: trainer.max_attempts,
        retry_backoff_ms: trainer.retry_backoff_ms
    }
  end

  defp validate_job_identity(%TrainingJob{idempotency_key: dispatch_id}, %{
         dispatch_id: dispatch_id
       })
       when is_binary(dispatch_id) and dispatch_id != "",
       do: :ok

  defp validate_job_identity(_job, %{dispatch_id: dispatch_id}),
    do: {:error, {:training_dispatch_job_identity_mismatch, dispatch_id}}

  defp validate_same_job(%TrainingJob{id: id}, %TrainingJob{id: id})
       when is_binary(id) and id != "",
       do: :ok

  defp validate_same_job(%TrainingJob{} = saved, %TrainingJob{} = reconciled),
    do: {:error, {:training_dispatch_reconciled_wrong_job, saved.id, reconciled.id}}

  defp safe_job_checkpoint(%TrainingJob{} = job) do
    checkpoint = job |> TrainingJob.dump() |> Imp.Redaction.drop_credentials()

    unsafe_field =
      Enum.find(
        ~w(id provider model result_model status_url cancel_url idempotency_key),
        fn field ->
          not credential_safe_locator?(Map.get(job, String.to_existing_atom(field)))
        end
      )

    cond do
      unsafe_field ->
        {:error, {:training_dispatch_unsafe_job_locator, unsafe_field}}

      credential_safe?(checkpoint) ->
        {:ok, checkpoint}

      true ->
        {:error, :training_dispatch_unsafe_job_checkpoint}
    end
  end

  defp credential_safe_locator?(nil), do: true
  defp credential_safe_locator?(value) when is_atom(value), do: true

  defp credential_safe_locator?(value) when is_binary(value),
    do: Imp.Redaction.redact(value) == value and safe_uri_components?(value)

  defp credential_safe_locator?(_value), do: false

  defp credential_safe?(value),
    do: Imp.Redaction.redact(value) == value and Imp.Redaction.drop_credentials(value) == value

  defp safe_uri_components?(value), do: safe_uri_components?(value, 0)

  defp safe_uri_components?(value, depth) when depth <= 4 do
    uri = URI.parse(value)

    is_nil(uri.userinfo) and
      safe_uri_path?(uri.path, depth) and
      safe_uri_component?(uri.query, depth) and
      safe_uri_component?(uri.fragment, depth) and
      case URI.decode_www_form(value) do
        ^value -> true
        decoded -> safe_uri_components?(decoded, depth + 1)
      end
  rescue
    _error -> false
  end

  defp safe_uri_components?(_value, _depth), do: false

  defp safe_uri_path?(nil, _depth), do: true

  defp safe_uri_path?(path, depth) do
    segments = String.split(path, "/", trim: true)

    Imp.Redaction.redact(path) == path and
      Enum.all?(segments, &safe_uri_path_segment?(&1, depth))
  end

  defp safe_uri_path_segment?(segment, depth) do
    case String.split(segment, "=", parts: 2) do
      [key, nested] ->
        not Imp.Redaction.credential_entry?(key, nested) and
          Imp.Redaction.redact(nested) == nested and
          safe_decoded_component?(nested, depth)

      [_plain] ->
        Imp.Redaction.redact(segment) == segment
    end
  end

  defp safe_uri_component?(nil, _depth), do: true

  defp safe_uri_component?(component, depth) do
    Imp.Redaction.redact(component) == component and
      component
      |> URI.query_decoder()
      |> Enum.all?(fn {key, nested} ->
        not Imp.Redaction.credential_entry?(key, nested) and
          Imp.Redaction.redact(nested) == nested and
          safe_nested_locator?(nested, depth)
      end)
  end

  defp safe_nested_locator?(value, depth) do
    case URI.parse(value) do
      %URI{scheme: scheme} when is_binary(scheme) -> safe_uri_components?(value, depth + 1)
      _other -> safe_decoded_component?(value, depth)
    end
  rescue
    _error -> false
  end

  defp safe_decoded_component?(value, depth) do
    case URI.decode_www_form(value) do
      ^value -> true
      decoded -> safe_uri_component?(decoded, depth + 1)
    end
  end

  # Stable semantic identity deliberately excludes credentials and BEAM-local
  # runtime handles. Provider/module identity plus safe configuration (including
  # endpoint, model, and method) remains bound so operational drift is rejected.
  defp semantic_identity(value) do
    case semantic_value(value) do
      :drop -> nil
      {:keep, normalized} -> normalized
    end
  end

  defp semantic_value(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__imp_runtime_module__, Atom.to_string(module))
    |> semantic_value()
  end

  defp semantic_value(map) when is_map(map) do
    normalized =
      Enum.reduce(map, %{}, fn {key, nested}, acc ->
        cond do
          runtime_key?(key) or Imp.Redaction.credential_entry?(key, nested) ->
            acc

          true ->
            case semantic_value(nested) do
              :drop -> acc
              {:keep, value} -> Map.put(acc, semantic_key(key), value)
            end
        end
      end)

    {:keep, normalized}
  end

  defp semantic_value(list) when is_list(list) do
    list = canonical_keyword_order(list)

    values =
      Enum.reduce(list, [], fn nested, acc ->
        case semantic_value(nested) do
          :drop -> acc
          {:keep, value} -> [value | acc]
        end
      end)
      |> Enum.reverse()

    {:keep, values}
  end

  defp semantic_value({key, nested}) when is_atom(key) or is_binary(key) do
    cond do
      runtime_key?(key) ->
        :drop

      Imp.Redaction.credential_entry?(key, nested) ->
        {:keep, [semantic_key(key), "[credential]"]}

      true ->
        case semantic_value(nested) do
          :drop -> :drop
          {:keep, value} -> {:keep, [semantic_key(key), value]}
        end
    end
  end

  defp semantic_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> semantic_value()
  end

  defp semantic_value(value) when is_pid(value) or is_port(value) or is_reference(value),
    do: :drop

  defp semantic_value(value) when is_function(value), do: :drop

  defp semantic_value(value) when is_binary(value), do: {:keep, semantic_binary(value)}
  defp semantic_value(value) when is_atom(value), do: {:keep, Atom.to_string(value)}

  defp semantic_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:keep, value}

  defp semantic_value(_value), do: :drop

  defp canonical_keyword_order(list) do
    if Keyword.keyword?(list) and
         list |> Keyword.keys() |> Enum.uniq() |> length() == length(list) do
      Enum.sort_by(list, fn {key, _value} -> Atom.to_string(key) end)
    else
      list
    end
  end

  defp semantic_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        query =
          if uri.query do
            uri.query
            |> URI.query_decoder()
            |> Enum.map(fn {key, nested} ->
              if Imp.Redaction.credential_entry?(key, nested) or
                   Imp.Redaction.redact(nested) != nested do
                {key, "[credential]"}
              else
                {key, nested}
              end
            end)
            |> URI.encode_query()
          end

        %{uri | userinfo: nil, query: query} |> URI.to_string()

      _other ->
        if Imp.Redaction.redact(value) == value, do: value, else: "[credential]"
    end
  rescue
    _error -> if(Imp.Redaction.redact(value) == value, do: value, else: "[credential]")
  end

  defp semantic_key(key) when is_atom(key), do: Atom.to_string(key)
  defp semantic_key(key) when is_binary(key), do: key
  defp semantic_key(key), do: inspect(key)

  defp runtime_key?(key) when is_atom(key) or is_binary(key) do
    normalized = key |> to_string() |> String.downcase()

    normalized in ~w(owner state transport handler callback dispatch_observer pid task process runtime) or
      String.starts_with?(normalized, "runtime_") or
      String.ends_with?(normalized, [
        "_callback",
        "_handler",
        "_pid",
        "_process",
        "_runtime",
        "_fn",
        "_fun",
        "_function",
        "_mapper",
        "_builder",
        "_preparer"
      ])
  end

  defp runtime_key?(_key), do: false

  defp digest_term(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp checksum(payload), do: "sha256:" <> digest_term(payload)

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp required_binary!(map, key) do
    case map[key] do
      value when is_binary(value) and value != "" -> value
      _other -> raise ArgumentError, "invalid training dispatch #{key}"
    end
  end

  defp load_method("sft"), do: :sft
  defp load_method("grpo"), do: :grpo
  defp load_method(other), do: other

  defp notify(nil, _phase, _intent), do: :ok

  defp notify(observer, phase, intent) when is_function(observer, 2) do
    observer.(phase, %{dispatch_id: intent.dispatch_id, identity_digest: intent.identity_digest})
  end

  defp notify(_observer, _phase, _intent),
    do: raise(ArgumentError, "training dispatch observer must be an arity-2 function")

  defp safe_message(error), do: error |> Exception.message() |> Imp.Redaction.redact()
end
