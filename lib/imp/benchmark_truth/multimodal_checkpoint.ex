defmodule Imp.BenchmarkTruth.MultimodalCheckpoint do
  @moduledoc false

  import Bitwise

  @schema_version 2
  @envelope_keys ~w(authentication payload payload_sha256)
  @authentication_keys ~w(algorithm key_id tag)
  @payload_keys ~w(completed identity in_progress schema_version)
  @intent_keys ~w(checkpoint_campaign_identity intent_recorded_at manifest_sample)
  @row_keys ~w(answer audit checkpoint_campaign_identity cost dispatch failure latency_us manifest_sample outcome provider score usage)
  @binding_keys ~w(assets delivery expected_capability expected_output family prompt_bytes prompt_sha256 sample_id sample_sha256)
  @asset_binding_keys ~w(asset_id bytes mime_type sha256)
  @audit_keys ~w(request response)
  @dispatch_keys ~w(count evidence req_llm_request_id transport)
  @provider_keys ~w(api api_evidence model model_evidence name provider_id_limitation provider_request_id provider_response_id)
  @usage_keys ~w(cache_classification cached_input_tokens input_tokens output_tokens total_tokens uncached_input_tokens)
  @cost_keys ~w(cached_input_nano_usd classification exact output_nano_usd total_nano_usd total_usd uncached_input_nano_usd)
  @request_audit_keys ~w(api body_sha256 dependency endpoint http_method model observed_at ordered_part_types parts req_llm_request_id serialization_boundary transport)
  @request_part_keys ~w(bytes content_sha256 mime_type type)
  @response_audit_keys ~w(http_status observed_at provider_id_limitations provider_request_id provider_response_id usage)
  @response_usage_keys ~w(cache_classification cached_input_tokens input_tokens output_tokens source total_tokens)

  def load!(path, identity, bindings) do
    checkpoint =
      case File.read(path) do
        {:ok, json} -> decode!(json, signing_key!(path))
        {:error, :enoent} -> new_checkpoint!(path, identity)
        {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
      end

    unless checkpoint["identity"] == identity do
      raise ArgumentError, "multimodal checkpoint campaign identity mismatch"
    end

    validate_in_progress!(checkpoint["in_progress"], identity, bindings)
    validate_completed!(checkpoint["completed"], identity, bindings)

    if map_size(checkpoint["in_progress"]) > 0 do
      ids = checkpoint["in_progress"] |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      raise ArgumentError,
            "ambiguous multimodal dispatch outcome for #{ids}; inspect provider logs and start a new checkpoint or explicitly reconcile the row"
    end

    write!(path, checkpoint)
    checkpoint
  end

  def record_intents!(path, checkpoint, samples, bindings) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    identity = checkpoint["identity"]

    updated =
      Enum.reduce(samples, checkpoint, fn sample, acc ->
        id = sample["id"]

        if Map.has_key?(acc["completed"], id) or Map.has_key?(acc["in_progress"], id) do
          raise ArgumentError, "duplicate multimodal dispatch intent for #{id}"
        end

        binding = Map.fetch!(bindings, id)

        put_in(acc, ["in_progress", id], %{
          "checkpoint_campaign_identity" => identity,
          "intent_recorded_at" => now,
          "manifest_sample" => binding
        })
      end)

    validate_in_progress!(updated["in_progress"], identity, bindings)
    write!(path, updated)
    updated
  end

  def record_outcome!(path, checkpoint, sample_id, row, bindings) do
    unless Map.has_key?(checkpoint["in_progress"], sample_id) do
      raise ArgumentError, "multimodal outcome without durable intent for #{sample_id}"
    end

    validate_row!(row, sample_id, checkpoint["identity"], Map.fetch!(bindings, sample_id))

    updated =
      checkpoint
      |> update_in(["in_progress"], &Map.delete(&1, sample_id))
      |> put_in(["completed", sample_id], row)

    validate_completed!(updated["completed"], checkpoint["identity"], bindings)
    write!(path, updated)
    updated
  end

  def completed_rows(checkpoint, sample_order) do
    Enum.flat_map(sample_order, fn id ->
      case checkpoint["completed"][id] do
        nil -> []
        row -> [row]
      end
    end)
  end

  def key_path(path), do: path <> ".hmac-key"

  def recompute_payload_sha256(payload), do: sha256(Jason.encode!(payload))

  defp new_checkpoint!(path, identity) do
    create_signing_key!(path)

    checkpoint = %{
      "completed" => %{},
      "identity" => identity,
      "in_progress" => %{},
      "schema_version" => @schema_version
    }

    write!(path, checkpoint)
  end

  defp validate_in_progress!(in_progress, identity, bindings) when is_map(in_progress) do
    Enum.each(in_progress, fn {sample_id, intent} ->
      exact_keys!(intent, @intent_keys, "checkpoint intent #{sample_id}")

      unless Map.has_key?(bindings, sample_id) and
               intent["manifest_sample"] == Map.fetch!(bindings, sample_id) and
               intent["checkpoint_campaign_identity"] == identity and
               is_binary(intent["intent_recorded_at"]) do
        raise ArgumentError, "invalid multimodal checkpoint intent for #{sample_id}"
      end
    end)
  end

  defp validate_in_progress!(_in_progress, _identity, _bindings) do
    raise ArgumentError, "malformed multimodal checkpoint in_progress map"
  end

  defp validate_completed!(completed, identity, bindings) when is_map(completed) do
    Enum.each(completed, fn {sample_id, row} ->
      binding = Map.get(bindings, sample_id)

      unless binding do
        raise ArgumentError, "checkpoint row #{sample_id} is absent from the checksummed manifest"
      end

      validate_row!(row, sample_id, identity, binding)
    end)

    row_sample_ids =
      Enum.map(completed, fn {_key, row} -> row["manifest_sample"]["sample_id"] end)

    unless Enum.uniq(row_sample_ids) == row_sample_ids do
      raise ArgumentError, "duplicate multimodal checkpoint sample rows"
    end

    dispatch_ids =
      completed
      |> Enum.map(fn {_key, row} -> row["dispatch"]["req_llm_request_id"] end)
      |> Enum.reject(&is_nil/1)

    unless Enum.uniq(dispatch_ids) == dispatch_ids do
      raise ArgumentError, "duplicate multimodal checkpoint dispatch evidence"
    end

    request_ids =
      completed
      |> Enum.map(fn {_key, row} -> row["provider"]["provider_request_id"] end)
      |> Enum.reject(&is_nil/1)

    unless Enum.uniq(request_ids) == request_ids do
      raise ArgumentError, "duplicate multimodal checkpoint provider request IDs"
    end

    response_ids =
      completed
      |> Enum.map(fn {_key, row} -> row["provider"]["provider_response_id"] end)
      |> Enum.reject(&is_nil/1)

    unless Enum.uniq(response_ids) == response_ids do
      raise ArgumentError, "duplicate multimodal checkpoint provider response IDs"
    end
  end

  defp validate_completed!(_completed, _identity, _bindings) do
    raise ArgumentError, "malformed multimodal checkpoint completed map"
  end

  defp validate_row!(row, sample_id, identity, binding) do
    exact_keys!(row, @row_keys, "checkpoint completed row #{sample_id}")

    unless row["checkpoint_campaign_identity"] == identity and row["manifest_sample"] == binding do
      raise ArgumentError, "checkpoint row #{sample_id} is not bound to this campaign manifest"
    end

    exact_keys!(binding, @binding_keys, "checkpoint sample binding #{sample_id}")
    validate_asset_bindings!(binding["assets"], sample_id)
    exact_keys!(row["audit"], @audit_keys, "checkpoint audit #{sample_id}")
    validate_optional_request_audit!(row["audit"]["request"], sample_id)
    validate_optional_response_audit!(row["audit"]["response"], sample_id)
    exact_keys!(row["dispatch"], @dispatch_keys, "checkpoint dispatch #{sample_id}")
    exact_keys!(row["provider"], @provider_keys, "checkpoint provider #{sample_id}")
    validate_nullable_usage!(row["usage"], sample_id)
    validate_nullable_cost!(row["cost"], sample_id)

    unless is_integer(row["latency_us"]) and row["latency_us"] >= 0 and
             is_number(row["score"]) and row["score"] in [0.0, 1.0] and
             is_binary(row["outcome"]) do
      raise ArgumentError, "checkpoint row #{sample_id} has malformed outcome fields"
    end

    validate_success!(row, sample_id, identity, binding)
  end

  defp validate_success!(%{"outcome" => "passed"} = row, sample_id, identity, binding) do
    provider = identity["provider"]

    valid? =
      row["score"] == 1.0 and is_nil(row["failure"]) and
        normalized_equal?(row["answer"], binding["expected_output"]) and
        row["dispatch"]["count"] == 1 and
        row["dispatch"]["evidence"] == "post_serialization_req_request_step" and
        nonempty?(row["dispatch"]["req_llm_request_id"]) and
        is_map(row["audit"]["request"]) and is_map(row["audit"]["response"]) and
        row["provider"]["name"] == provider["name"] and
        row["provider"]["model"] == provider["model"] and
        row["provider"]["api"] == provider["api"] and
        row["usage"]["cache_classification"] == "provider_reported" and
        row["cost"]["exact"] == true and
        row["cost"] == expected_cost(row["usage"], provider["pricing"])

    unless valid? do
      raise ArgumentError,
            "checkpoint passing row #{sample_id} lacks exact dispatch/usage/outcome proof"
    end
  end

  defp validate_success!(row, sample_id, _identity, _binding) do
    if row["score"] != 0.0 do
      raise ArgumentError, "checkpoint non-passing row #{sample_id} must have score 0.0"
    end
  end

  defp validate_asset_bindings!(assets, sample_id) when is_list(assets) and assets != [] do
    Enum.each(assets, fn asset ->
      exact_keys!(asset, @asset_binding_keys, "checkpoint asset binding #{sample_id}")
    end)
  end

  defp validate_asset_bindings!(_assets, sample_id) do
    raise ArgumentError, "checkpoint sample #{sample_id} has malformed asset bindings"
  end

  defp validate_optional_request_audit!(nil, _sample_id), do: :ok

  defp validate_optional_request_audit!(audit, sample_id) do
    exact_keys!(audit, @request_audit_keys, "checkpoint request audit #{sample_id}")

    unless is_list(audit["parts"]) and is_list(audit["ordered_part_types"]) do
      raise ArgumentError, "checkpoint request audit #{sample_id} has malformed parts"
    end

    Enum.each(audit["parts"], fn part ->
      exact_keys!(part, @request_part_keys, "checkpoint request part #{sample_id}")
    end)
  end

  defp validate_optional_response_audit!(nil, _sample_id), do: :ok

  defp validate_optional_response_audit!(audit, sample_id) do
    exact_keys!(audit, @response_audit_keys, "checkpoint response audit #{sample_id}")
    exact_keys!(audit["usage"], @response_usage_keys, "checkpoint response usage #{sample_id}")
  end

  defp validate_nullable_usage!(nil, _sample_id), do: :ok

  defp validate_nullable_usage!(usage, sample_id) do
    exact_keys!(usage, @usage_keys, "checkpoint usage #{sample_id}")
  end

  defp validate_nullable_cost!(nil, _sample_id), do: :ok

  defp validate_nullable_cost!(cost, sample_id) do
    exact_keys!(cost, @cost_keys, "checkpoint cost #{sample_id}")
  end

  defp expected_cost(usage, pricing) do
    cached = usage["cached_input_tokens"] * pricing["cached_input_nano_usd_per_token"]
    uncached = usage["uncached_input_tokens"] * pricing["input_nano_usd_per_token"]
    output = usage["output_tokens"] * pricing["output_nano_usd_per_token"]
    total = cached + uncached + output

    %{
      "cached_input_nano_usd" => cached,
      "classification" => "exact_from_provider_usage",
      "exact" => true,
      "output_nano_usd" => output,
      "total_nano_usd" => total,
      "total_usd" => nano_usd(total),
      "uncached_input_nano_usd" => uncached
    }
  end

  defp decode!(json, key) do
    envelope = Jason.decode!(json)
    exact_keys!(envelope, @envelope_keys, "checkpoint envelope")
    exact_keys!(envelope["authentication"], @authentication_keys, "checkpoint authentication")

    payload = envelope["payload"]
    exact_keys!(payload, @payload_keys, "checkpoint payload")

    unless payload["schema_version"] == @schema_version do
      raise ArgumentError, "unsupported multimodal checkpoint schema"
    end

    authentication = envelope["authentication"]
    expected_sha = recompute_payload_sha256(payload)
    expected_tag = hmac(key, payload)

    unless authentication["algorithm"] == "hmac-sha256" and
             secure_equal?(authentication["key_id"], sha256(key)) and
             secure_equal?(envelope["payload_sha256"], expected_sha) and
             secure_equal?(authentication["tag"], expected_tag) do
      raise ArgumentError, "multimodal checkpoint authentication mismatch"
    end

    payload
  end

  defp write!(path, checkpoint) do
    File.mkdir_p!(Path.dirname(path))
    key = signing_key!(path)

    envelope = %{
      "authentication" => %{
        "algorithm" => "hmac-sha256",
        "key_id" => sha256(key),
        "tag" => hmac(key, checkpoint)
      },
      "payload" => checkpoint,
      "payload_sha256" => recompute_payload_sha256(checkpoint)
    }

    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(envelope, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    checkpoint
  end

  defp create_signing_key!(path) do
    File.mkdir_p!(Path.dirname(path))
    key_path = key_path(path)

    if File.exists?(key_path) do
      raise ArgumentError, "orphaned multimodal checkpoint signing key at #{key_path}"
    end

    case File.write(key_path, :crypto.strong_rand_bytes(32), [:exclusive, :sync]) do
      :ok -> File.chmod!(key_path, 0o600)
      {:error, reason} -> raise File.Error, reason: reason, action: "write file", path: key_path
    end
  end

  defp signing_key!(path) do
    key_path = key_path(path)
    stat = File.stat!(key_path)

    unless stat.type == :regular and stat.size == 32 and (stat.mode &&& 0o077) == 0 do
      raise ArgumentError, "multimodal checkpoint signing key must be a 32-byte owner-only file"
    end

    File.read!(key_path)
  end

  defp exact_keys!(map, expected, context) when is_map(map) do
    unless Enum.sort(Map.keys(map)) == Enum.sort(expected) do
      raise ArgumentError, "#{context} has an inexact schema"
    end
  end

  defp exact_keys!(_map, _expected, context), do: raise(ArgumentError, "#{context} must be a map")

  defp normalized_equal?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp normalized_equal?(left, right), do: left == right
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp hmac(key, payload) do
    :crypto.mac(:hmac, :sha256, key, :erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp nano_usd(nano) do
    whole = div(nano, 1_000_000_000)
    fraction = nano |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{whole}.#{fraction}"
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
