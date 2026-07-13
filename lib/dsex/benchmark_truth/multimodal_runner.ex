defmodule DSEx.BenchmarkTruth.MultimodalRunner do
  @moduledoc false

  alias DSEx.Adapters.Types
  alias DSEx.BenchmarkTruth.MultimodalCheckpoint, as: Checkpoint
  alias DSEx.BenchmarkTruth.MultimodalManifest, as: Manifest

  @default_manifest "benchmarks/data/multimodal/manifest.json"
  @request_audit_message :dsex_multimodal_serialized_request_audit
  @response_audit_message :dsex_multimodal_provider_response_audit

  def run(opts \\ []) do
    mode = Keyword.fetch!(opts, :mode)
    unless mode in [:plan, :live], do: raise(ArgumentError, "mode must be :plan or :live")

    root = Keyword.get(opts, :root, File.cwd!()) |> Path.expand()
    manifest_path = Keyword.get(opts, :manifest, Path.join(root, @default_manifest))
    manifest = Manifest.load!(manifest_path, root: root)
    Manifest.runtime_dependency!(manifest.payload)
    max_concurrency = validate_concurrency!(Keyword.get(opts, :max_concurrency, 2))

    case mode do
      :plan -> plan_artifact(manifest, root, max_concurrency)
      :live -> run_live(manifest, root, max_concurrency, opts)
    end
  end

  @doc false
  def audit_serialized_request(%Req.Request{} = request, owner, sample_id, dependency) do
    audit = serialized_request_audit!(request, dependency)
    send(owner, {@request_audit_message, sample_id, audit})
    request
  end

  @doc false
  def audit_provider_response(
        {%Req.Request{} = request, %Req.Response{} = response},
        owner,
        sample_id,
        provider
      ) do
    audit = provider_response_audit(request, response, provider)
    send(owner, {@response_audit_message, sample_id, audit})
    {request, response}
  end

  defp run_live(manifest, root, max_concurrency, opts) do
    payload = manifest.payload
    api_key = Keyword.fetch!(opts, :api_key)

    unless is_binary(api_key) and api_key != "" do
      raise ArgumentError, "live multimodal benchmark requires a non-empty process-scoped API key"
    end

    checkpoint_path =
      Keyword.get(
        opts,
        :checkpoint,
        Path.join(
          root,
          "benchmarks/results/multimodal-checkpoints/#{payload["campaign_id"]}.json"
        )
      )

    identity = checkpoint_identity(manifest)
    bindings = Manifest.sample_bindings(payload)
    checkpoint = Checkpoint.load!(checkpoint_path, identity, bindings)
    sample_order = Enum.map(payload["samples"], & &1["id"])
    completed = Map.keys(checkpoint["completed"]) |> MapSet.new()
    remaining = Enum.reject(payload["samples"], &MapSet.member?(completed, &1["id"]))
    resumed = map_size(checkpoint["completed"])

    context = %{
      api_key: api_key,
      assets: materialized_assets(payload["assets"], root),
      bindings: bindings,
      checkpoint_identity: identity,
      client_opts: Keyword.get(opts, :client_opts, []),
      manifest: payload,
      req_module: Keyword.get(opts, :req_module, ReqLLM)
    }

    {checkpoint, dispatched, written} =
      remaining
      |> Enum.chunk_every(max_concurrency)
      |> Enum.reduce({checkpoint, 0, 0}, fn chunk, {checkpoint, dispatched, written} ->
        checkpoint = Checkpoint.record_intents!(checkpoint_path, checkpoint, chunk, bindings)
        rows = dispatch_chunk(chunk, context, max_concurrency)

        Enum.reduce(rows, {checkpoint, dispatched, written}, fn {sample_id, row},
                                                                {current, dispatch_count,
                                                                 row_count} ->
          current =
            Checkpoint.record_outcome!(checkpoint_path, current, sample_id, row, bindings)

          next_written = row_count + 1
          next_dispatched = dispatch_count + row["dispatch"]["count"]

          if Keyword.get(opts, :crash_after_rows) == next_written do
            raise "injected multimodal runner crash after durable outcome #{next_written}"
          end

          {current, next_dispatched, next_written}
        end)
      end)

    rows = Checkpoint.completed_rows(checkpoint, sample_order)

    artifact =
      report(manifest, rows, :live, max_concurrency, checkpoint_path, %{
        dispatched: dispatched,
        resumed: resumed,
        written: written
      })

    assert_artifact_safe!(artifact, api_key, context.assets)
    artifact
  end

  defp dispatch_chunk(samples, context, max_concurrency) do
    samples
    |> Task.async_stream(&execute_sample(&1, context),
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: context.manifest["provider"]["generation"]["timeout_ms"] + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(samples)
    |> Enum.map(fn
      {{:ok, row}, sample} ->
        {sample["id"], row}

      {{:exit, reason}, sample} ->
        {sample["id"], execution_failure_row(sample, context, reason, nil)}
    end)
  end

  defp execute_sample(sample, context) do
    started = System.monotonic_time(:microsecond)
    do_execute_sample(sample, context, started)
  end

  defp do_execute_sample(sample, context, started) do
    {attachment, _intent_shape} = attachment(sample, context.assets)
    provider = context.manifest["provider"]
    client_opts = install_audit_plugin(context.client_opts, self(), sample["id"], provider)

    lm_opts =
      [api_key: context.api_key, req_module: context.req_module]
      |> Keyword.merge(client_opts)

    lm = DSEx.req_llm(provider["req_llm_model"], lm_opts)
    messages = [%{role: :user, content: [attachment, sample["prompt"]]}]

    result =
      DSEx.Clients.ReqLLM.generate(lm, messages, generation_opts(provider["generation"]))

    latency = System.monotonic_time(:microsecond) - started
    audits = collect_audits(sample["id"])
    result_row(sample, result, latency, provider, context, audits)
  rescue
    error ->
      execution_failure_row(
        sample,
        context,
        scrub_failure(Exception.message(error), context.api_key),
        started,
        collect_audits(sample["id"])
      )
  catch
    kind, reason ->
      execution_failure_row(
        sample,
        context,
        scrub_failure({kind, reason}, context.api_key),
        started,
        collect_audits(sample["id"])
      )
  end

  defp install_audit_plugin(client_opts, owner, sample_id, provider) do
    unless Keyword.keyword?(client_opts) do
      raise ArgumentError, "multimodal client_opts must be a keyword list"
    end

    http_opts = Keyword.get(client_opts, :req_http_options, [])

    unless Keyword.keyword?(http_opts) do
      raise ArgumentError, "multimodal req_http_options must be a keyword list"
    end

    existing_plugins = Keyword.get(http_opts, :plugins, [])

    unless is_list(existing_plugins) do
      raise ArgumentError, "multimodal req_http_options plugins must be a list"
    end

    dependency = provider["req_llm_dependency"]

    audit_plugin = fn request ->
      request
      |> Req.Request.append_request_steps(
        dsex_multimodal_serialized_request_audit:
          {__MODULE__, :audit_serialized_request, [owner, sample_id, dependency]}
      )
      |> Req.Request.append_response_steps(
        dsex_multimodal_provider_response_audit:
          {__MODULE__, :audit_provider_response, [owner, sample_id, provider]}
      )
    end

    updated_http_opts = Keyword.put(http_opts, :plugins, existing_plugins ++ [audit_plugin])
    Keyword.put(client_opts, :req_http_options, updated_http_opts)
  end

  defp collect_audits(sample_id) do
    %{
      "request" => receive_audit(@request_audit_message, sample_id),
      "response" => receive_audit(@response_audit_message, sample_id)
    }
  end

  defp receive_audit(message, sample_id) do
    receive do
      {^message, ^sample_id, audit} -> audit
    after
      0 -> nil
    end
  end

  defp attachment(%{"delivery" => "typed_image_data_uri", "asset_ids" => [asset_id]}, assets) do
    asset = Map.fetch!(assets, asset_id)
    data_uri = "data:#{asset["mime_type"]};base64,#{Base.encode64(asset["bytes_data"])}"

    value = %Types.Image{
      url: data_uri,
      mime_type: asset["mime_type"],
      metadata: %{asset_id: asset_id}
    }

    {value, intent_shape(asset_id, asset, "DSEx.Adapters.Types.Image", "image_url")}
  end

  defp attachment(%{"delivery" => "typed_native_file", "asset_ids" => [asset_id]}, assets) do
    asset = Map.fetch!(assets, asset_id)

    value = %Types.File{
      path: asset["absolute_path"],
      mime_type: asset["mime_type"],
      metadata: %{asset_id: asset_id}
    }

    {value, intent_shape(asset_id, asset, "DSEx.Adapters.Types.File", "file")}
  end

  defp intent_shape(asset_id, asset, dsex_type, req_llm_type) do
    %{
      "asset_id" => asset_id,
      "bytes" => byte_size(asset["bytes_data"]),
      "dsex_type" => dsex_type,
      "evidence_level" => "pre_dispatch_intent_only",
      "mime_type" => asset["mime_type"],
      "req_llm_content_part" => req_llm_type,
      "sha256" => asset["sha256"]
    }
  end

  defp result_row(sample, {:ok, response}, latency, provider, context, audits) do
    with {:ok, output, metadata} <- unwrap_response(response),
         :ok <- validate_request_audit(audits["request"], sample, provider, context.bindings),
         :ok <- validate_response_audit(audits["response"]),
         {:ok, usage} <- strict_usage(metadata, audits["response"]),
         :ok <- effective_identity(metadata, provider),
         {:ok, answer} <- parse_answer(output) do
      correct? = normalize(answer) == normalize(sample["gold"])
      cost = cost(usage, provider["pricing"])
      classified? = usage["cache_classification"] == "provider_reported"
      passed? = correct? and classified?

      base_row(sample, latency, context, audits)
      |> Map.merge(%{
        "answer" => answer,
        "cost" => cost,
        "failure" =>
          cond do
            not correct? -> "exact_match_failed"
            not classified? -> "cached_input_classification_missing"
            true -> nil
          end,
        "outcome" =>
          if(passed?,
            do: "passed",
            else: if(correct?, do: "usage_unclassified", else: "wrong_answer")
          ),
        "provider" => provider_evidence(metadata, audits, provider),
        "score" => if(passed?, do: 1.0, else: 0.0),
        "usage" => usage
      })
    else
      {:error, {:malformed_audit, reason}} ->
        failed_row(
          sample,
          context,
          audits,
          latency,
          "malformed_audit",
          scrub_failure(reason, context.api_key)
        )

      {:error, {:malformed_usage, reason}} ->
        failed_row(
          sample,
          context,
          audits,
          latency,
          "malformed_usage",
          scrub_failure(reason, context.api_key)
        )

      {:error, {:identity_mismatch, reason}} ->
        failed_row(
          sample,
          context,
          audits,
          latency,
          "identity_error",
          scrub_failure(reason, context.api_key)
        )

      {:error, {:malformed_output, reason}} ->
        failed_row(
          sample,
          context,
          audits,
          latency,
          "malformed_output",
          scrub_failure(reason, context.api_key)
        )

      {:error, reason} ->
        failed_row(
          sample,
          context,
          audits,
          latency,
          "malformed_output",
          scrub_failure(reason, context.api_key)
        )
    end
  end

  defp result_row(sample, {:error, reason}, latency, _provider, context, audits) do
    failure = scrub_failure(reason, context.api_key)
    outcome = if capability_error?(failure), do: "capability_error", else: "provider_error"
    failed_row(sample, context, audits, latency, outcome, failure)
  end

  defp result_row(sample, other, latency, _provider, context, audits) do
    failed_row(
      sample,
      context,
      audits,
      latency,
      "malformed_output",
      scrub_failure(other, context.api_key)
    )
  end

  defp unwrap_response(%{
         __dsex_lm_output__: output,
         __dsex_lm_metadata__: %{req_llm: metadata}
       }),
       do: {:ok, output, metadata}

  defp unwrap_response(%{
         "__dsex_lm_output__" => output,
         "__dsex_lm_metadata__" => %{"req_llm" => metadata}
       }),
       do: {:ok, output, metadata}

  defp unwrap_response(_), do: {:error, {:malformed_output, "ReqLLM metadata envelope missing"}}

  defp validate_request_audit(nil, _sample, _provider, _bindings) do
    {:error, {:malformed_audit, "post-serialization request audit missing"}}
  end

  defp validate_request_audit(audit, sample, provider, bindings) do
    binding = Map.fetch!(bindings, sample["id"])
    expected_parts = expected_serialized_parts(binding, provider["api"])

    if audit["api"] == provider["api"] and audit["model"] == provider["model"] and
         audit["dependency"] == provider["req_llm_dependency"] and
         audit["serialization_boundary"] ==
           "Req request step after ReqLLM provider encode_body and before transport" and
         audit["parts"] == expected_parts and
         audit["ordered_part_types"] == Enum.map(expected_parts, & &1["type"]) do
      :ok
    else
      {:error, {:malformed_audit, "serialized request did not match the signed sample/provider"}}
    end
  end

  defp validate_response_audit(%{"http_status" => status}) when status in 200..299, do: :ok

  defp validate_response_audit(nil),
    do: {:error, {:malformed_audit, "provider response audit missing"}}

  defp validate_response_audit(_audit),
    do: {:error, {:malformed_audit, "provider response audit did not record success"}}

  defp strict_usage(metadata, response_audit) do
    usage = metadata[:usage] || metadata["usage"]
    input = map_value(usage, :input_tokens)
    output = map_value(usage, :output_tokens)
    total = map_value(usage, :total_tokens)
    normalized_cached = map_value(usage, :cached_tokens)
    raw = response_audit["usage"]

    valid_base? =
      is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
        total == input + output and raw["input_tokens"] == input and
        raw["output_tokens"] == output and raw["total_tokens"] == total

    cond do
      not valid_base? ->
        {:error, {:malformed_usage, "provider and ReqLLM token totals were inconsistent"}}

      raw["cache_classification"] == "provider_reported" and
        is_integer(raw["cached_input_tokens"]) and raw["cached_input_tokens"] >= 0 and
        raw["cached_input_tokens"] <= input and normalized_cached == raw["cached_input_tokens"] ->
        cached = raw["cached_input_tokens"]

        {:ok,
         %{
           "cache_classification" => "provider_reported",
           "cached_input_tokens" => cached,
           "input_tokens" => input,
           "output_tokens" => output,
           "total_tokens" => total,
           "uncached_input_tokens" => input - cached
         }}

      raw["cache_classification"] == "missing" ->
        {:ok,
         %{
           "cache_classification" => "missing",
           "cached_input_tokens" => nil,
           "input_tokens" => input,
           "output_tokens" => output,
           "total_tokens" => total,
           "uncached_input_tokens" => nil
         }}

      true ->
        {:error, {:malformed_usage, "cached input token classification was inconsistent"}}
    end
  end

  defp effective_identity(metadata, provider) do
    model = metadata[:model] || metadata["model"]
    api = metadata[:api] || metadata["api"]

    cond do
      model != provider["model"] ->
        {:error,
         {:identity_mismatch,
          "effective model #{inspect(model)} did not match #{provider["model"]}"}}

      api != provider["api"] ->
        {:error,
         {:identity_mismatch, "effective API #{inspect(api)} did not match #{provider["api"]}"}}

      true ->
        :ok
    end
  end

  defp parse_answer(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"answer" => answer} = decoded}
      when map_size(decoded) == 1 and (is_binary(answer) or is_integer(answer)) ->
        {:ok, answer}

      {:ok, _decoded} ->
        {:error,
         {:malformed_output, "response must contain exactly one string/integer answer field"}}

      {:error, error} ->
        {:error, {:malformed_output, Exception.message(error)}}
    end
  end

  defp parse_answer(_), do: {:error, {:malformed_output, "response body must be JSON text"}}

  defp report(manifest, rows, mode, max_concurrency, checkpoint_path, run_stats) do
    payload = manifest.payload
    families = family_summaries(rows, payload["scoring"]["family_thresholds"])
    gate = claim_gate(manifest, rows, mode)
    proof_complete? = gate["eligible"]
    usage = total_usage(rows)

    %{
      "artifact_schema" => "dsex.multimodal_quality.v2",
      "campaign_id" => payload["campaign_id"],
      "checkpoint" =>
        if(mode == :live,
          do: %{"authentication" => "hmac-sha256-sidecar", "path" => checkpoint_path},
          else: nil
        ),
      "claim_gate" => gate,
      "claims" => %{
        "audio" => %{"claimed" => false, "status" => "unsupported_unproven"},
        "document_quality" => proof_complete?,
        "image_quality" => proof_complete?,
        "multimodal_quality" => proof_complete?,
        "native_file_support" => proof_complete?,
        "rendered_document_images" => %{
          "claimed_as_native_file_support" => false,
          "executed" => false
        }
      },
      "families" => families,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "input_evidence" => %{
        "claim_authorizing_boundary" =>
          "post-serialization Req request step immediately before transport",
        "pre_dispatch_intents" => planned_input_shapes(payload, manifest_root(manifest)),
        "pre_dispatch_intents_authorize_claims" => false
      },
      "limitations" =>
        payload["limitations"] ++
          [
            "The checkpoint HMAC prevents edits without the owner-only sidecar, but a local principal able to read both files can forge it.",
            "Provider request IDs are recorded only when exposed in response headers; missing IDs are explicit row limitations and are not described as response-metadata proof."
          ],
      "manifest" => %{
        "path" => manifest.path,
        "payload_sha256" => manifest.sha256,
        "signature" => payload["signature"]
      },
      "mode" => Atom.to_string(mode),
      "provider" => Map.drop(payload["provider"], ["credential_env"]),
      "rows" => rows,
      "runner" => %{
        "dispatch" => "DSEx.Clients.ReqLLM.generate/3",
        "max_concurrency" => max_concurrency,
        "request_audit" => "Req request step after provider serialization and before transport",
        "resumable" => mode == :live
      },
      "summary" => %{
        "complete" => length(rows) == length(payload["samples"]),
        "dispatched" => run_stats.dispatched,
        "failed" => Enum.count(rows, &(&1["score"] != 1.0)),
        "passed" => Enum.count(rows, &(&1["score"] == 1.0)),
        "resumed" => run_stats.resumed,
        "rows" => length(rows),
        "samples" => length(payload["samples"]),
        "written" => run_stats.written
      },
      "usage" => Map.put(usage, "cost", total_cost(rows))
    }
  end

  defp plan_artifact(manifest, _root, max_concurrency) do
    payload = manifest.payload
    identity = checkpoint_identity(manifest)
    bindings = Manifest.sample_bindings(payload)

    rows =
      Enum.map(payload["samples"], fn sample ->
        context = %{
          bindings: bindings,
          checkpoint_identity: identity,
          manifest: payload
        }

        base_row(sample, 0, context, %{"request" => nil, "response" => nil})
        |> Map.merge(%{
          "answer" => nil,
          "cost" => nil,
          "failure" => "provider_not_called_in_plan_mode",
          "outcome" => "planned",
          "provider" => empty_provider_evidence(payload["provider"]),
          "score" => 0.0,
          "usage" => nil
        })
      end)

    report(manifest, rows, :plan, max_concurrency, nil, %{
      dispatched: 0,
      resumed: 0,
      written: 0
    })
  end

  defp claim_gate(manifest, rows, mode) do
    payload = manifest.payload
    expected_ids = Enum.map(payload["samples"], & &1["id"])
    actual_ids = Enum.map(rows, &get_in(&1, ["manifest_sample", "sample_id"]))
    provider = payload["provider"]

    checks = [
      {mode == :live, "mode_is_not_live"},
      {actual_ids == expected_ids and Enum.uniq(actual_ids) == actual_ids,
       "rows_do_not_exactly_match_manifest_samples"},
      {Enum.all?(rows, &(&1["outcome"] == "passed" and &1["score"] == 1.0)),
       "not_all_rows_are_successful"},
      {Enum.all?(rows, &(get_in(&1, ["dispatch", "count"]) == 1)),
       "nonzero_dispatch_evidence_missing"},
      {unique_nonempty?(rows, ["dispatch", "req_llm_request_id"]),
       "dispatch_evidence_is_missing_or_duplicated"},
      {Enum.all?(rows, &(get_in(&1, ["audit", "request", "endpoint"]) == provider["endpoint"])),
       "serialized_endpoint_mismatch"},
      {Enum.all?(rows, &(get_in(&1, ["audit", "request", "transport"]) == "finch")),
       "non_provider_transport_detected"},
      {Enum.all?(rows, &row_audit_exact?(&1, provider)),
       "request_or_response_audit_is_inconsistent"},
      {Enum.all?(rows, &row_identity_exact?(&1, provider)), "provider_model_or_api_mismatch"},
      {Enum.all?(rows, &row_usage_cost_exact?(&1, provider["pricing"])),
       "usage_or_cost_is_not_exact"},
      {provider_ids_sufficient?(rows, provider), "required_provider_response_id_missing"},
      {unique_optional?(rows, ["provider", "provider_request_id"]),
       "provider_request_ids_are_duplicated"},
      {unique_optional?(rows, ["provider", "provider_response_id"]),
       "provider_response_ids_are_duplicated"}
    ]

    rejections = for {false, reason} <- checks, do: reason

    %{
      "eligible" => rejections == [],
      "rejections" => rejections,
      "required_evidence" => [
        "exact_manifest_row_set",
        "post_serialization_request_audit",
        "unique_req_llm_dispatch_id",
        "provider_endpoint_model_api",
        "provider_reported_cache_classification",
        "recomputed_exact_cost",
        "provider_response_id_when_profile_requires_it",
        "hmac_authenticated_checkpoint_campaign"
      ]
    }
  end

  defp row_identity_exact?(row, provider) do
    request = get_in(row, ["audit", "request"]) || %{}
    evidence = row["provider"] || %{}

    request["api"] == provider["api"] and request["model"] == provider["model"] and
      request["dependency"] == provider["req_llm_dependency"] and
      evidence["name"] == provider["name"] and evidence["api"] == provider["api"] and
      evidence["model"] == provider["model"] and
      evidence["api_evidence"] == "post_serialization_endpoint" and
      evidence["model_evidence"] ==
        ["post_serialization_request_body", "decoded_provider_response"]
  end

  defp row_audit_exact?(row, provider) do
    request = get_in(row, ["audit", "request"]) || %{}
    response = get_in(row, ["audit", "response"]) || %{}
    response_usage = response["usage"] || %{}
    usage = row["usage"] || %{}
    dispatch = row["dispatch"] || %{}
    evidence = row["provider"] || %{}
    binding = row["manifest_sample"] || %{}
    expected_parts = expected_serialized_parts(binding, provider["api"])

    request["http_method"] == "POST" and
      request["serialization_boundary"] ==
        "Req request step after ReqLLM provider encode_body and before transport" and
      sha256_hex?(request["body_sha256"]) and request["parts"] == expected_parts and
      request["ordered_part_types"] == Enum.map(expected_parts, & &1["type"]) and
      request["req_llm_request_id"] == dispatch["req_llm_request_id"] and
      response["http_status"] in 200..299 and
      response["provider_request_id"] == evidence["provider_request_id"] and
      response["provider_response_id"] == evidence["provider_response_id"] and
      response_usage["cache_classification"] == usage["cache_classification"] and
      response_usage["source"] == cache_usage_source(provider["api"]) and
      response_usage["cached_input_tokens"] == usage["cached_input_tokens"] and
      response_usage["input_tokens"] == usage["input_tokens"] and
      response_usage["output_tokens"] == usage["output_tokens"] and
      response_usage["total_tokens"] == usage["total_tokens"]
  end

  defp row_usage_cost_exact?(row, pricing) do
    usage = row["usage"]
    cost = row["cost"]

    is_map(usage) and usage["cache_classification"] == "provider_reported" and
      is_map(cost) and cost["exact"] == true and cost == cost(usage, pricing)
  end

  defp provider_ids_sufficient?(rows, %{
         "identity_evidence" => "serialized_request_and_provider_response_id_required"
       }) do
    Enum.all?(rows, &nonempty?(get_in(&1, ["provider", "provider_response_id"])))
  end

  defp provider_ids_sufficient?(_rows, _provider), do: true

  defp cache_usage_source("responses"),
    do: "response.usage.input_tokens_details.cached_tokens"

  defp cache_usage_source("generateContent"),
    do: "response.usageMetadata.cachedContentTokenCount"

  defp unique_nonempty?(rows, path) do
    values = Enum.map(rows, &get_in(&1, path))
    Enum.all?(values, &nonempty?/1) and Enum.uniq(values) == values
  end

  defp unique_optional?(rows, path) do
    values = rows |> Enum.map(&get_in(&1, path)) |> Enum.reject(&is_nil/1)
    Enum.uniq(values) == values
  end

  defp family_summaries(rows, thresholds) do
    Map.new(thresholds, fn {family, threshold} ->
      family_rows = Enum.filter(rows, &(get_in(&1, ["manifest_sample", "family"]) == family))

      score =
        if family_rows == [],
          do: 0.0,
          else: Enum.sum(Enum.map(family_rows, & &1["score"])) / length(family_rows)

      {family,
       %{
         "passed" => Enum.count(family_rows, &(&1["score"] == 1.0)),
         "passing" => family_rows != [] and score >= threshold,
         "score" => score,
         "threshold" => threshold,
         "total" => length(family_rows)
       }}
    end)
  end

  defp base_row(sample, latency, context, audits) do
    %{
      "answer" => nil,
      "audit" => audits,
      "checkpoint_campaign_identity" => context.checkpoint_identity,
      "cost" => nil,
      "dispatch" => dispatch_evidence(audits["request"]),
      "failure" => nil,
      "latency_us" => latency,
      "manifest_sample" => Map.fetch!(context.bindings, sample["id"]),
      "outcome" => nil,
      "provider" => empty_provider_evidence(context.manifest["provider"]),
      "score" => 0.0,
      "usage" => nil
    }
  end

  defp failed_row(sample, context, audits, latency, outcome, failure) do
    base_row(sample, latency, context, audits)
    |> Map.merge(%{
      "failure" => failure,
      "outcome" => outcome,
      "provider" => provider_evidence(nil, audits, context.manifest["provider"])
    })
  end

  defp execution_failure_row(sample, context, reason, started, audits \\ nil) do
    latency = if started, do: System.monotonic_time(:microsecond) - started, else: 0
    audits = audits || %{"request" => nil, "response" => nil}

    failed_row(
      sample,
      context,
      audits,
      latency,
      "runner_error",
      failure_envelope(reason, context.api_key)
    )
  end

  defp dispatch_evidence(nil) do
    %{
      "count" => 0,
      "evidence" => nil,
      "req_llm_request_id" => nil,
      "transport" => nil
    }
  end

  defp dispatch_evidence(request_audit) do
    %{
      "count" => 1,
      "evidence" => "post_serialization_req_request_step",
      "req_llm_request_id" => request_audit["req_llm_request_id"],
      "transport" => request_audit["transport"]
    }
  end

  defp empty_provider_evidence(provider) do
    %{
      "api" => nil,
      "api_evidence" => nil,
      "model" => nil,
      "model_evidence" => [],
      "name" => provider["name"],
      "provider_id_limitation" => "provider response was not available",
      "provider_request_id" => nil,
      "provider_response_id" => nil
    }
  end

  defp provider_evidence(metadata, audits, provider) do
    request = audits["request"] || %{}
    response = audits["response"] || %{}
    model = if metadata, do: metadata[:model] || metadata["model"], else: nil
    api = if metadata, do: metadata[:api] || metadata["api"], else: nil
    limitations = response["provider_id_limitations"] || ["provider response was not available"]

    %{
      "api" => api,
      "api_evidence" => if(request["api"] == provider["api"], do: "post_serialization_endpoint"),
      "model" => model,
      "model_evidence" =>
        if(request["model"] == provider["model"] and model == provider["model"],
          do: ["post_serialization_request_body", "decoded_provider_response"],
          else: []
        ),
      "name" => provider["name"],
      "provider_id_limitation" =>
        if(limitations == [], do: nil, else: Enum.join(limitations, "; ")),
      "provider_request_id" => response["provider_request_id"],
      "provider_response_id" => response["provider_response_id"]
    }
  end

  defp generation_opts(settings) do
    settings
    |> Map.take(~w(max_tokens seed temperature top_p))
    |> Enum.map(fn {key, value} -> {String.to_existing_atom(key), value} end)
    |> Keyword.put(:timeout, settings["timeout_ms"])
  end

  defp checkpoint_identity(manifest) do
    provider = manifest.payload["provider"]

    %{
      "campaign_id" => manifest.payload["campaign_id"],
      "checkpoint_schema_version" => 2,
      "generation" => provider["generation"],
      "manifest_sha256" => manifest.sha256,
      "provider" =>
        Map.take(
          provider,
          ~w(api endpoint model name pricing profile req_llm_dependency req_llm_model)
        ),
      "sample_set_sha256" =>
        manifest.payload
        |> Manifest.sample_bindings()
        |> Jason.encode!()
        |> sha256()
    }
  end

  defp materialized_assets(assets, root) do
    Map.new(assets, fn {id, asset} ->
      path = Path.expand(asset["path"], root)
      {id, asset |> Map.put("absolute_path", path) |> Map.put("bytes_data", File.read!(path))}
    end)
  end

  defp planned_input_shapes(payload, root) do
    assets = materialized_assets(payload["assets"], root)

    Enum.map(payload["samples"], fn sample ->
      {_attachment, shape} = attachment(sample, assets)
      Map.put(shape, "sample_id", sample["id"])
    end)
  end

  defp manifest_root(manifest) do
    manifest.path
    |> Path.dirname()
    |> Path.join("../../..")
    |> Path.expand()
  end

  defp total_usage(rows) do
    usages = Enum.map(rows, & &1["usage"])
    present = Enum.filter(usages, &is_map/1)

    all_classified? =
      present != [] and Enum.all?(present, &(&1["cache_classification"] == "provider_reported"))

    %{
      "cache_classification" => if(all_classified?, do: "provider_reported", else: "incomplete"),
      "cached_input_tokens" =>
        if(all_classified?,
          do: Enum.sum(Enum.map(present, & &1["cached_input_tokens"])),
          else: nil
        ),
      "input_tokens" => Enum.sum(Enum.map(present, & &1["input_tokens"])),
      "output_tokens" => Enum.sum(Enum.map(present, & &1["output_tokens"])),
      "total_tokens" => Enum.sum(Enum.map(present, & &1["total_tokens"])),
      "uncached_input_tokens" =>
        if(all_classified?,
          do: Enum.sum(Enum.map(present, & &1["uncached_input_tokens"])),
          else: nil
        )
    }
  end

  defp cost(%{"cache_classification" => "provider_reported"} = usage, pricing) do
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

  defp cost(_usage, _pricing) do
    %{
      "cached_input_nano_usd" => nil,
      "classification" => "unavailable_without_cached_input_classification",
      "exact" => false,
      "output_nano_usd" => nil,
      "total_nano_usd" => nil,
      "total_usd" => nil,
      "uncached_input_nano_usd" => nil
    }
  end

  defp total_cost(rows) do
    costs = Enum.map(rows, & &1["cost"])
    exact? = costs != [] and Enum.all?(costs, &(is_map(&1) and &1["exact"] == true))

    if exact? do
      cached = Enum.sum(Enum.map(costs, & &1["cached_input_nano_usd"]))
      uncached = Enum.sum(Enum.map(costs, & &1["uncached_input_nano_usd"]))
      output = Enum.sum(Enum.map(costs, & &1["output_nano_usd"]))
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
    else
      cost(nil, nil)
    end
  end

  defp serialized_request_audit!(request, dependency) do
    body = request.body

    unless is_binary(body) do
      raise ArgumentError, "ReqLLM provider request body was not serialized"
    end

    decoded = Jason.decode!(body)
    endpoint = sanitized_endpoint(request.url)
    api = api_for_endpoint(endpoint)
    parts = serialized_parts(decoded, api)

    %{
      "api" => api,
      "body_sha256" => sha256(body),
      "dependency" => dependency,
      "endpoint" => endpoint,
      "http_method" => request.method |> to_string() |> String.upcase(),
      "model" => decoded["model"] || model_from_endpoint(endpoint),
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "ordered_part_types" => Enum.map(parts, & &1["type"]),
      "parts" => parts,
      "req_llm_request_id" => request.private[:req_llm_request_id] |> to_string_or_nil(),
      "serialization_boundary" =>
        "Req request step after ReqLLM provider encode_body and before transport",
      "transport" => request_transport(request)
    }
  end

  defp serialized_parts(body, "responses") do
    body
    |> Map.get("input", [])
    |> Enum.flat_map(fn item -> if is_map(item), do: List.wrap(item["content"]), else: [] end)
    |> Enum.map(&serialized_openai_part!/1)
  end

  defp serialized_parts(body, "generateContent") do
    body
    |> Map.get("contents", [])
    |> Enum.flat_map(fn item -> if is_map(item), do: List.wrap(item["parts"]), else: [] end)
    |> Enum.map(&serialized_google_part!/1)
  end

  defp serialized_parts(_body, _api), do: []

  defp serialized_openai_part!(%{"type" => "input_text", "text" => text}) do
    audited_part("input_text", "text/plain; charset=utf-8", text)
  end

  defp serialized_openai_part!(%{"type" => "input_image", "image_url" => uri}) do
    {mime_type, bytes} = decode_data_uri!(uri)
    audited_part("input_image", mime_type, bytes)
  end

  defp serialized_openai_part!(%{"type" => "input_file", "file_data" => uri}) do
    {mime_type, bytes} = decode_data_uri!(uri)
    audited_part("input_file", mime_type, bytes)
  end

  defp serialized_openai_part!(part) do
    audited_part(part["type"] || "unknown", nil, Jason.encode!(part))
  end

  defp serialized_google_part!(%{"text" => text}) do
    audited_part("text", "text/plain; charset=utf-8", text)
  end

  defp serialized_google_part!(%{"inline_data" => inline}) do
    data = inline["data"]

    case Base.decode64(data || "") do
      {:ok, bytes} -> audited_part("inline_data", inline["mime_type"], bytes)
      :error -> raise ArgumentError, "serialized Google inline_data was not valid base64"
    end
  end

  defp serialized_google_part!(part) do
    audited_part("unknown", nil, Jason.encode!(part))
  end

  defp audited_part(type, mime_type, bytes) when is_binary(bytes) do
    %{
      "bytes" => byte_size(bytes),
      "content_sha256" => sha256(bytes),
      "mime_type" => mime_type,
      "type" => type
    }
  end

  defp expected_serialized_parts(binding, "responses") do
    [asset] = binding["assets"]

    attachment_type =
      if binding["delivery"] == "typed_image_data_uri", do: "input_image", else: "input_file"

    [
      %{
        "bytes" => asset["bytes"],
        "content_sha256" => asset["sha256"],
        "mime_type" => asset["mime_type"],
        "type" => attachment_type
      },
      %{
        "bytes" => binding["prompt_bytes"],
        "content_sha256" => binding["prompt_sha256"],
        "mime_type" => "text/plain; charset=utf-8",
        "type" => "input_text"
      }
    ]
  end

  defp expected_serialized_parts(binding, "generateContent") do
    [asset] = binding["assets"]

    [
      %{
        "bytes" => asset["bytes"],
        "content_sha256" => asset["sha256"],
        "mime_type" => asset["mime_type"],
        "type" => "inline_data"
      },
      %{
        "bytes" => binding["prompt_bytes"],
        "content_sha256" => binding["prompt_sha256"],
        "mime_type" => "text/plain; charset=utf-8",
        "type" => "text"
      }
    ]
  end

  defp provider_response_audit(_request, response, provider) do
    body = if is_map(response.body), do: response.body, else: %{}
    provider_request_id = response_header_id(response)
    provider_response_id = primitive_field(body["id"] || body["responseId"])

    limitations =
      []
      |> maybe_add_limitation(is_nil(provider_request_id), "provider request ID not exposed")
      |> maybe_add_limitation(is_nil(provider_response_id), "provider response ID not exposed")

    %{
      "http_status" => response.status,
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "provider_id_limitations" => limitations,
      "provider_request_id" => provider_request_id,
      "provider_response_id" => provider_response_id,
      "usage" => response_usage_audit(body, provider["api"])
    }
  end

  defp response_usage_audit(body, "responses") do
    usage = body["usage"] || %{}
    details = usage["input_tokens_details"] || %{}
    cache_present? = is_map(details) and Map.has_key?(details, "cached_tokens")

    %{
      "cache_classification" => if(cache_present?, do: "provider_reported", else: "missing"),
      "cached_input_tokens" => if(cache_present?, do: details["cached_tokens"], else: nil),
      "input_tokens" => usage["input_tokens"],
      "output_tokens" => usage["output_tokens"],
      "source" =>
        if(cache_present?, do: "response.usage.input_tokens_details.cached_tokens", else: nil),
      "total_tokens" => usage["total_tokens"]
    }
  end

  defp response_usage_audit(body, "generateContent") do
    usage = body["usageMetadata"] || body["usage_metadata"] || %{}

    {cache_present?, cached} =
      cond do
        Map.has_key?(usage, "cachedContentTokenCount") ->
          {true, usage["cachedContentTokenCount"]}

        Map.has_key?(usage, "cached_content_token_count") ->
          {true, usage["cached_content_token_count"]}

        true ->
          {false, nil}
      end

    input = usage["promptTokenCount"] || usage["prompt_token_count"]
    output = usage["candidatesTokenCount"] || usage["candidates_token_count"]
    total = usage["totalTokenCount"] || usage["total_token_count"]

    %{
      "cache_classification" => if(cache_present?, do: "provider_reported", else: "missing"),
      "cached_input_tokens" => cached,
      "input_tokens" => input,
      "output_tokens" => output,
      "source" =>
        if(cache_present?, do: "response.usageMetadata.cachedContentTokenCount", else: nil),
      "total_tokens" => total
    }
  end

  defp response_usage_audit(_body, _api) do
    %{
      "cache_classification" => "missing",
      "cached_input_tokens" => nil,
      "input_tokens" => nil,
      "output_tokens" => nil,
      "source" => nil,
      "total_tokens" => nil
    }
  end

  defp sanitized_endpoint(%URI{} = uri), do: %{uri | query: nil, fragment: nil} |> URI.to_string()
  defp sanitized_endpoint(value), do: value |> to_string() |> URI.parse() |> sanitized_endpoint()

  defp api_for_endpoint(endpoint) do
    cond do
      String.ends_with?(endpoint, "/responses") -> "responses"
      String.ends_with?(endpoint, ":generateContent") -> "generateContent"
      true -> "unknown"
    end
  end

  defp model_from_endpoint(endpoint) do
    case Regex.run(~r{/models/([^/:]+):}, endpoint) do
      [_, model] -> model
      _ -> nil
    end
  end

  defp request_transport(request) do
    cond do
      request.options[:plug] != nil -> "local_plug"
      request.options[:finch_request] != nil -> "custom_finch_request"
      default_finch_adapter?(request.adapter) -> "finch"
      true -> "custom_adapter"
    end
  end

  defp default_finch_adapter?(adapter) when is_function(adapter, 1) do
    Function.info(adapter, :module) == {:module, Req.Steps} and
      Function.info(adapter, :name) == {:name, :run_finch}
  end

  defp default_finch_adapter?(_adapter), do: false

  defp response_header_id(response) do
    headers = Req.get_headers_list(response)

    Enum.find_value(["x-request-id", "request-id", "openai-request-id"], fn expected ->
      Enum.find_value(headers, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          if String.downcase(name) == expected, do: value

        _ ->
          nil
      end)
    end)
  end

  defp decode_data_uri!(uri) when is_binary(uri) do
    case Regex.run(~r/^data:([^;,]+);base64,(.+)$/s, uri) do
      [_, mime_type, encoded] ->
        case Base.decode64(encoded) do
          {:ok, bytes} -> {mime_type, bytes}
          :error -> raise ArgumentError, "serialized multimodal data URI was not valid base64"
        end

      _ ->
        raise ArgumentError, "serialized multimodal part was not an inline base64 data URI"
    end
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value

  defp capability_error?(failure) do
    down = failure |> Map.fetch!("message") |> String.downcase()

    Enum.any?(
      ["unsupported", "capability", "modality", "mime type", "file input"],
      &String.contains?(down, &1)
    )
  end

  defp scrub_failure(value, api_key), do: failure_envelope(value, api_key)

  defp failure_envelope(value, api_key) do
    %{
      "category" => failure_category(value),
      "exception" => exception_name(value),
      "http_status" => safe_field(value, :status),
      "message" =>
        value |> safe_failure_message() |> redact_failure_text(api_key) |> bound_text(),
      "provider_code" => nested_safe_field(value, :code),
      "request_id" => nested_safe_field(value, :request_id)
    }
  end

  defp failure_category({category, _}) when is_atom(category), do: Atom.to_string(category)
  defp failure_category(%{class: class}) when is_atom(class), do: Atom.to_string(class)
  defp failure_category(%{__struct__: module}), do: module |> Module.split() |> Enum.join(".")
  defp failure_category(_), do: "provider_failure"

  defp exception_name(%{__struct__: module}), do: module |> Module.split() |> Enum.join(".")
  defp exception_name({_category, value}), do: exception_name(value)
  defp exception_name(_), do: nil

  defp safe_failure_message(value) do
    failure_message(value)
  rescue
    _error -> "provider failure message unavailable"
  catch
    _kind, _reason -> "provider failure message unavailable"
  end

  defp failure_message(value) when is_exception(value), do: Exception.message(value)

  defp failure_message({category, value}) when is_atom(category),
    do: "#{category}: #{failure_message(value)}"

  defp failure_message(value) when is_binary(value), do: value
  defp failure_message(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp safe_field(%{__struct__: _} = value, key), do: primitive_field(Map.get(value, key))
  defp safe_field(value, key) when is_map(value), do: primitive_field(map_value(value, key))
  defp safe_field({_category, value}, key), do: safe_field(value, key)
  defp safe_field(_value, _key), do: nil

  defp nested_safe_field(value, key) do
    safe_field(value, key) ||
      case safe_field_container(value, :response_body) do
        body when is_map(body) -> primitive_field(map_value(body, key))
        _ -> nil
      end
  end

  defp safe_field_container(%{__struct__: _} = value, key), do: Map.get(value, key)
  defp safe_field_container(value, key) when is_map(value), do: map_value(value, key)
  defp safe_field_container({_category, value}, key), do: safe_field_container(value, key)
  defp safe_field_container(_value, _key), do: nil

  defp primitive_field(value) when is_binary(value) or is_integer(value), do: value
  defp primitive_field(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp primitive_field(_value), do: nil

  defp redact_failure_text(text, nil), do: DSEx.Redaction.redact(text)

  defp redact_failure_text(text, api_key) do
    text
    |> String.replace(api_key, "[REDACTED]")
    |> DSEx.Redaction.redact()
  end

  defp bound_text(text), do: String.slice(text, 0, 2_000)

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil

  defp validate_concurrency!(value) when is_integer(value) and value in 1..8, do: value

  defp validate_concurrency!(value) do
    raise ArgumentError,
          "max_concurrency must be an integer from 1 through 8, got: #{inspect(value)}"
  end

  defp assert_artifact_safe!(artifact, api_key, assets) do
    encoded = Jason.encode!(artifact)

    forbidden =
      [api_key, "data:"] ++
        Enum.map(assets, fn {_id, asset} -> Base.encode64(asset["bytes_data"]) end)

    case Enum.find(forbidden, &(&1 != "" and String.contains?(encoded, &1))) do
      nil ->
        artifact

      _ ->
        raise ArgumentError, "multimodal artifact contains a credential or encoded asset payload"
    end
  end

  defp maybe_add_limitation(list, true, limitation), do: list ++ [limitation]
  defp maybe_add_limitation(list, false, _limitation), do: list
  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp sha256_hex?(value), do: is_binary(value) and Regex.match?(~r/^[0-9a-f]{64}$/, value)

  defp nano_usd(nano) do
    whole = div(nano, 1_000_000_000)
    fraction = nano |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{whole}.#{fraction}"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
