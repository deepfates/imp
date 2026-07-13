defmodule DSEx.BenchmarkTruth.MultimodalRunner do
  @moduledoc false

  alias DSEx.Adapters.Types
  alias DSEx.BenchmarkTruth.MultimodalCheckpoint, as: Checkpoint
  alias DSEx.BenchmarkTruth.MultimodalManifest, as: Manifest

  @default_manifest "benchmarks/data/multimodal/manifest.json"

  def run(opts \\ []) do
    mode = Keyword.fetch!(opts, :mode)
    unless mode in [:plan, :live], do: raise(ArgumentError, "mode must be :plan or :live")

    root = Keyword.get(opts, :root, File.cwd!()) |> Path.expand()
    manifest_path = Keyword.get(opts, :manifest, Path.join(root, @default_manifest))
    manifest = Manifest.load!(manifest_path, root: root)
    max_concurrency = validate_concurrency!(Keyword.get(opts, :max_concurrency, 2))

    case mode do
      :plan -> plan_artifact(manifest, root, max_concurrency)
      :live -> run_live(manifest, root, max_concurrency, opts)
    end
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
    checkpoint = Checkpoint.load!(checkpoint_path, identity)
    sample_order = Enum.map(payload["samples"], & &1["id"])
    completed = Map.keys(checkpoint["completed"]) |> MapSet.new()
    remaining = Enum.reject(payload["samples"], &MapSet.member?(completed, &1["id"]))

    context = %{
      api_key: api_key,
      assets: materialized_assets(payload["assets"], root),
      client_opts: Keyword.get(opts, :client_opts, []),
      manifest: payload,
      req_module: Keyword.get(opts, :req_module, ReqLLM)
    }

    {checkpoint, _written} =
      remaining
      |> Enum.chunk_every(max_concurrency)
      |> Enum.reduce({checkpoint, map_size(checkpoint["completed"])}, fn chunk,
                                                                         {checkpoint, written} ->
        checkpoint = Checkpoint.record_intents!(checkpoint_path, checkpoint, chunk)
        rows = dispatch_chunk(chunk, context, max_concurrency)

        Enum.reduce(rows, {checkpoint, written}, fn {sample_id, row}, {current, count} ->
          current = Checkpoint.record_outcome!(checkpoint_path, current, sample_id, row)
          next_count = count + 1

          if Keyword.get(opts, :crash_after_rows) == next_count do
            raise "injected multimodal runner crash after durable outcome #{next_count}"
          end

          {current, next_count}
        end)
      end)

    rows = Checkpoint.completed_rows(checkpoint, sample_order)
    artifact = report(manifest, rows, :live, max_concurrency, checkpoint_path)
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
      {{:ok, row}, sample} -> {sample["id"], row}
      {{:exit, reason}, sample} -> {sample["id"], execution_failure_row(sample, reason)}
    end)
  end

  defp execute_sample(sample, context) do
    started = System.monotonic_time(:microsecond)
    do_execute_sample(sample, context, started)
  end

  defp do_execute_sample(sample, context, started) do
    {attachment, shape} = attachment(sample, context.assets)
    provider = context.manifest["provider"]

    lm_opts =
      [api_key: context.api_key, req_module: context.req_module]
      |> Keyword.merge(context.client_opts)

    lm = DSEx.req_llm(provider["req_llm_model"], lm_opts)
    messages = [%{role: :user, content: [attachment, sample["prompt"]]}]

    result =
      DSEx.Clients.ReqLLM.generate(lm, messages, generation_opts(provider["generation"]))

    latency = System.monotonic_time(:microsecond) - started
    result_row(sample, shape, result, latency, provider, context.api_key)
  rescue
    error ->
      execution_failure_row(
        sample,
        scrub_failure(Exception.message(error), context.api_key),
        started
      )
  catch
    kind, reason ->
      execution_failure_row(sample, scrub_failure({kind, reason}, context.api_key), started)
  end

  defp attachment(%{"delivery" => "typed_image_data_uri", "asset_ids" => [asset_id]}, assets) do
    asset = Map.fetch!(assets, asset_id)
    data_uri = "data:#{asset["mime_type"]};base64,#{Base.encode64(asset["bytes_data"])}"

    value = %Types.Image{
      url: data_uri,
      mime_type: asset["mime_type"],
      metadata: %{asset_id: asset_id}
    }

    shape = %{
      "asset_id" => asset_id,
      "bytes" => byte_size(asset["bytes_data"]),
      "dsex_type" => "DSEx.Adapters.Types.Image",
      "mime_type" => asset["mime_type"],
      "req_llm_content_part" => "image_url",
      "sha256" => asset["sha256"],
      "transport" => "inline_data_uri_redacted"
    }

    {value, shape}
  end

  defp attachment(%{"delivery" => "typed_native_file", "asset_ids" => [asset_id]}, assets) do
    asset = Map.fetch!(assets, asset_id)

    value = %Types.File{
      path: asset["absolute_path"],
      mime_type: asset["mime_type"],
      metadata: %{asset_id: asset_id}
    }

    shape = %{
      "asset_id" => asset_id,
      "bytes" => byte_size(asset["bytes_data"]),
      "dsex_type" => "DSEx.Adapters.Types.File",
      "mime_type" => asset["mime_type"],
      "req_llm_content_part" => "file",
      "sha256" => asset["sha256"],
      "transport" => "inline_binary_redacted"
    }

    {value, shape}
  end

  defp result_row(sample, shape, {:ok, response}, latency, provider, api_key) do
    with {:ok, output, metadata} <- unwrap_response(response),
         {:ok, usage} <- strict_usage(metadata),
         :ok <- effective_identity(metadata, provider),
         {:ok, answer} <- parse_answer(output) do
      correct? = normalize(answer) == normalize(sample["gold"])

      base_row(sample, shape, latency)
      |> Map.merge(%{
        "answer" => answer,
        "cost" => cost(usage, provider["pricing"]),
        "effective_api" => metadata[:api] || metadata["api"] || provider["api"],
        "effective_api_evidence" =>
          if(metadata[:api] || metadata["api"],
            do: "provider_response_metadata",
            else: "pinned_req_llm_google_adapter_audit"
          ),
        "effective_model" => metadata[:model] || metadata["model"],
        "failure" => if(correct?, do: nil, else: "exact_match_failed"),
        "outcome" => if(correct?, do: "passed", else: "wrong_answer"),
        "score" => if(correct?, do: 1.0, else: 0.0),
        "usage" => usage
      })
    else
      {:error, {:malformed_usage, reason}} ->
        failed_row(sample, shape, latency, "malformed_usage", scrub_failure(reason, api_key))

      {:error, {:identity_mismatch, reason}} ->
        failed_row(sample, shape, latency, "identity_error", scrub_failure(reason, api_key))

      {:error, {:malformed_output, reason}} ->
        failed_row(sample, shape, latency, "malformed_output", scrub_failure(reason, api_key))

      {:error, reason} ->
        failed_row(sample, shape, latency, "malformed_output", scrub_failure(reason, api_key))
    end
  end

  defp result_row(sample, shape, {:error, reason}, latency, _provider, api_key) do
    text = scrub_failure(reason, api_key)
    outcome = if capability_error?(text), do: "capability_error", else: "provider_error"
    failed_row(sample, shape, latency, outcome, text)
  end

  defp result_row(sample, shape, other, latency, _provider, api_key),
    do: failed_row(sample, shape, latency, "malformed_output", scrub_failure(other, api_key))

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

  defp strict_usage(metadata) do
    usage = metadata[:usage] || metadata["usage"]
    input = map_value(usage, :input_tokens)
    output = map_value(usage, :output_tokens)

    if is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
      {:ok,
       %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}}
    else
      {:error, {:malformed_usage, "input_tokens and output_tokens must be non-negative integers"}}
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

      api not in [nil, provider["api"]] ->
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

  defp report(manifest, rows, mode, max_concurrency, checkpoint_path) do
    payload = manifest.payload
    families = family_summaries(rows, payload["scoring"]["family_thresholds"])
    required = payload["claim_policy"]["required_families"]

    proof_complete? =
      mode == :live and length(rows) == length(payload["samples"]) and
        Enum.all?(required, &get_in(families, [&1, "passing"]))

    usage = total_usage(rows)

    %{
      "artifact_schema" => "dsex.multimodal_quality.v1",
      "campaign_id" => payload["campaign_id"],
      "checkpoint" => if(mode == :live, do: checkpoint_path, else: nil),
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
      "content_part_shapes" => Enum.map(rows, & &1["content_part_shape"]) |> Enum.uniq(),
      "families" => families,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "limitations" => payload["limitations"],
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
        "resumable" => mode == :live
      },
      "summary" => %{
        "complete" => length(rows) == length(payload["samples"]),
        "failed" => Enum.count(rows, &(&1["score"] != 1.0)),
        "passed" => Enum.count(rows, &(&1["score"] == 1.0)),
        "total" => length(payload["samples"])
      },
      "usage" => Map.put(usage, "cost", total_cost(rows))
    }
  end

  defp plan_artifact(manifest, root, max_concurrency) do
    rows =
      Enum.map(manifest.payload["samples"], fn sample ->
        {_attachment, shape} =
          attachment(sample, materialized_assets(manifest.payload["assets"], root))

        base_row(sample, shape, 0)
        |> Map.merge(%{
          "answer" => nil,
          "cost" => nil,
          "effective_api" => nil,
          "effective_api_evidence" => nil,
          "effective_model" => nil,
          "failure" => "provider_not_called_in_plan_mode",
          "outcome" => "planned",
          "score" => 0.0,
          "usage" => nil
        })
      end)

    report(manifest, rows, :plan, max_concurrency, nil)
  end

  defp family_summaries(rows, thresholds) do
    Map.new(thresholds, fn {family, threshold} ->
      family_rows = Enum.filter(rows, &(&1["family"] == family))

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

  defp base_row(sample, shape, latency) do
    %{
      "content_part_shape" => shape,
      "expected_capability" => sample["expected_capability"],
      "family" => sample["family"],
      "gold" => sample["gold"],
      "latency_us" => latency,
      "prompt_sha256" => sha256(sample["prompt"]),
      "sample_id" => sample["id"]
    }
  end

  defp failed_row(sample, shape, latency, outcome, failure) do
    base_row(sample, shape, latency)
    |> Map.merge(%{
      "answer" => nil,
      "cost" => nil,
      "effective_api" => nil,
      "effective_api_evidence" => nil,
      "effective_model" => nil,
      "failure" => failure,
      "outcome" => outcome,
      "score" => 0.0,
      "usage" => nil
    })
  end

  defp execution_failure_row(sample, reason, started \\ nil) do
    latency = if started, do: System.monotonic_time(:microsecond) - started, else: 0

    base_row(sample, %{"unavailable" => true}, latency)
    |> Map.merge(%{
      "answer" => nil,
      "cost" => nil,
      "effective_api" => nil,
      "effective_api_evidence" => nil,
      "effective_model" => nil,
      "failure" => inspect(reason),
      "outcome" => "runner_error",
      "score" => 0.0,
      "usage" => nil
    })
  end

  defp generation_opts(settings) do
    [
      temperature: settings["temperature"],
      top_p: settings["top_p"],
      seed: settings["seed"],
      max_tokens: settings["max_tokens"],
      timeout: settings["timeout_ms"]
    ]
  end

  defp checkpoint_identity(manifest) do
    provider = manifest.payload["provider"]

    %{
      "api" => provider["api"],
      "campaign_id" => manifest.payload["campaign_id"],
      "generation" => provider["generation"],
      "manifest_sha256" => manifest.sha256,
      "req_llm_model" => provider["req_llm_model"]
    }
  end

  defp materialized_assets(assets, root) do
    Map.new(assets, fn {id, asset} ->
      path = Path.expand(asset["path"], root)
      {id, asset |> Map.put("absolute_path", path) |> Map.put("bytes_data", File.read!(path))}
    end)
  end

  defp total_usage(rows) do
    Enum.reduce(rows, %{"input_tokens" => 0, "output_tokens" => 0, "total_tokens" => 0}, fn row,
                                                                                            acc ->
      case row["usage"] do
        nil -> acc
        usage -> Map.new(acc, fn {key, value} -> {key, value + usage[key]} end)
      end
    end)
  end

  defp cost(usage, pricing) do
    input = usage["input_tokens"] * pricing["input_nano_usd_per_token"]
    output = usage["output_tokens"] * pricing["output_nano_usd_per_token"]
    nano = input + output

    %{
      "input_nano_usd" => input,
      "output_nano_usd" => output,
      "total_nano_usd" => nano,
      "total_usd" => nano_usd(nano)
    }
  end

  defp total_cost(rows) do
    nano = Enum.sum(Enum.map(rows, &(get_in(&1, ["cost", "total_nano_usd"]) || 0)))
    %{"total_nano_usd" => nano, "total_usd" => nano_usd(nano)}
  end

  defp nano_usd(nano) do
    whole = div(nano, 1_000_000_000)
    fraction = nano |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")
    "#{whole}.#{fraction}"
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value

  defp capability_error?(text) do
    down = String.downcase(text)

    Enum.any?(
      ["unsupported", "capability", "modality", "mime type", "file input"],
      &String.contains?(down, &1)
    )
  end

  defp scrub_failure(value, api_key) do
    value
    |> DSEx.Redaction.redact()
    |> inspect()
    |> String.replace(api_key, "[REDACTED]")
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_map, _key), do: nil

  defp validate_concurrency!(value) when is_integer(value) and value in 1..8, do: value

  defp validate_concurrency!(value),
    do:
      raise(
        ArgumentError,
        "max_concurrency must be an integer from 1 through 8, got: #{inspect(value)}"
      )

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

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
