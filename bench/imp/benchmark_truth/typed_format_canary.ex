defmodule Imp.BenchmarkTruth.TypedFormatCanary do
  @moduledoc false

  alias Imp.BenchmarkTruth.{CampaignBudget, OpenRouterFreeGuard}

  @campaign_id "openrouter-free-typed-format-canary-v1"
  @signature "code -> status: enum[ok]"
  @instructions "Return the only allowed status for this synthetic format canary."
  @input %{code: "FORMAT-CANARY-7"}
  @seed 7
  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "imp_typed_format_canary",
      strict: true,
      schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"status" => %{"type" => "string", "enum" => ["ok"]}},
        "required" => ["status"]
      }
    }
  }

  def run(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    manifest_path = Keyword.fetch!(opts, :manifest) |> Path.expand()
    manifest_bytes = File.read!(manifest_path)
    manifest = Jason.decode!(manifest_bytes)
    candidates = validate_manifest!(manifest)

    results =
      Enum.map(candidates, fn candidate ->
        run_candidate(candidate, api_key, opts)
      end)

    %{
      "schema_version" => 1,
      "campaign" => @campaign_id,
      "generated_at" => now(),
      "git_sha" => git_sha(),
      "manifest" => %{
        "path" => manifest_path,
        "sha256" => sha256(manifest_bytes),
        "status_at_launch" => manifest["status"]
      },
      "synthetic_case" => manifest["synthetic_case"],
      "results" => results,
      "summary" => summarize(results),
      "scope" =>
        "One synthetic typed-format call per exact-free candidate. No optimizer, support-ticket test row, held-out label, or effectiveness claim is involved."
    }
  end

  def audit_request(%Req.Request{} = request, owner) do
    body = decode_body(request.body)
    provider_opts = request.options[:provider_options] || []

    send(owner, {
      :imp_typed_format_request_audit,
      %{
        "model" => map_value(body, :model) || request.options[:model],
        "provider" =>
          map_value(body, :provider) || request.options[:openrouter_provider] ||
            provider_opts[:openrouter_provider],
        "usage" =>
          map_value(body, :usage) || request.options[:openrouter_usage] ||
            provider_opts[:openrouter_usage],
        "response_format" =>
          map_value(body, :response_format) || request.options[:response_format] ||
            provider_opts[:response_format],
        "max_tokens" => map_value(body, :max_tokens) || request.options[:max_tokens],
        "reasoning_effort" =>
          map_value(body, :reasoning_effort) || request.options[:reasoning_effort]
      }
    })

    request
  end

  defp run_candidate(candidate, api_key, opts) do
    model = candidate["id"]
    max_output_tokens = candidate["max_output_tokens"]
    catalog = catalog_entry!(candidate, opts)
    {:ok, budget} = start_budget(max_output_tokens)
    {:ok, ledger} = OpenRouterFreeGuard.start_ledger()
    telemetry_id = CampaignBudget.attach_req_llm(budget)
    owner = self()

    audit_plugin = fn request ->
      Req.Request.append_request_steps(request,
        imp_typed_format_request_audit: {__MODULE__, :audit_request, [owner]}
      )
    end

    req_http_options = [plugins: [audit_plugin]]

    lm =
      OpenRouterFreeGuard.strict_lm(api_key, budget, ledger, @seed,
        model: model,
        max_output_tokens: max_output_tokens,
        reasoning_effort: parse_reasoning_effort(candidate["reasoning_effort"]),
        base_url: Keyword.get(opts, :base_url),
        req_http_options: req_http_options
      )

    program =
      @signature
      |> Imp.signature(@instructions)
      |> Imp.predict(
        lm: lm,
        adapter: Imp.Adapter.JSON,
        config: [response_format: @response_format, json_retries: 0]
      )

    started = System.monotonic_time(:millisecond)

    result =
      try do
        Imp.call(program, @input)
      after
        :telemetry.detach(telemetry_id)
      end

    audit = receive_audit()
    snapshot = CampaignBudget.snapshot(budget)
    response = OpenRouterFreeGuard.ledger_snapshot(ledger)

    request_validation = validate_request_audit(audit, candidate)
    result_validation = validate_result(result, response, snapshot, request_validation)

    %{
      "candidate" => candidate,
      "catalog" => catalog,
      "request_audit" => audit,
      "request_validation" => request_validation,
      "result" => result_record(result),
      "response_accounting" => response,
      "budget" => snapshot,
      "format_status" => result_validation,
      "wall_seconds" => elapsed_seconds(started)
    }
  end

  defp catalog_entry!(candidate, opts) do
    model = candidate["id"]

    entry =
      case Keyword.get(opts, :catalog) do
        nil -> OpenRouterFreeGuard.current_catalog!(model)
        catalog when is_map(catalog) -> Map.fetch!(catalog, model)
      end

    required = candidate["catalog_supported_parameters"]
    supported = entry["supported_parameters"] || []

    unless Enum.all?(required, &(&1 in supported)) do
      raise "OpenRouter catalog no longer advertises required format parameters for #{model}"
    end

    entry
  end

  defp start_budget(max_output_tokens) do
    CampaignBudget.start_link(
      limits: %{
        requests: 1,
        input_tokens: 20_000,
        output_tokens: max_output_tokens,
        usd: 0.0
      },
      pricing: %{"input_per_million" => 0.0, "output_per_million" => 0.0},
      default_max_output_tokens: max_output_tokens
    )
  end

  defp validate_request_audit(audit, candidate) do
    expected_reasoning = candidate["reasoning_effort"]
    response_format = audit && audit["response_format"]
    schema = response_format && map_value(response_format, :json_schema)
    json_schema = schema && map_value(schema, :schema)
    properties = json_schema && map_value(json_schema, :properties)
    status = properties && map_value(properties, :status)

    checks = %{
      "exact_model" => audit && audit["model"] == candidate["id"],
      "provider_guard" =>
        audit && stringify(audit["provider"]) == stringify(OpenRouterFreeGuard.provider_guard()),
      "usage_include" => audit && map_value(audit["usage"], :include) == true,
      "max_output_tokens" => audit && audit["max_tokens"] == candidate["max_output_tokens"],
      "reasoning_effort" => audit && audit["reasoning_effort"] == expected_reasoning,
      "json_schema_type" => response_format && map_value(response_format, :type) == "json_schema",
      "json_schema_strict" => schema && map_value(schema, :strict) == true,
      "json_schema_required" => json_schema && map_value(json_schema, :required) == ["status"],
      "json_schema_enum" => status && map_value(status, :enum) == ["ok"]
    }

    %{"passed" => Enum.all?(checks, fn {_key, value} -> value == true end), "checks" => checks}
  end

  defp validate_result(result, ledger, snapshot, request_validation) do
    rows = ledger["responses"] || []
    row = List.last(rows)

    checks = %{
      "request_valid" => request_validation["passed"],
      "one_logical_request" => snapshot["requests"] == 1,
      "one_transport_attempt" => snapshot["transport_attempts"] == 1,
      "zero_cumulative_cost" => get_in(snapshot, ["usage", "usd"]) in [0, 0.0],
      "guard_passed" => row && row["status"] == "passed",
      "finish_stop" => row && row["finish_reason"] == "stop",
      "content_present" => row && row["bounded_safe_excerpt"] not in [nil, "\"\""],
      "typed_status_ok" =>
        match?({:ok, %Imp.Prediction{}}, result) and typed_status(result) == "ok"
    }

    %{
      "passed" => Enum.all?(checks, fn {_key, value} -> value == true end),
      "checks" => checks
    }
  end

  defp typed_status({:ok, prediction}), do: Imp.get(prediction, :status)
  defp typed_status(_result), do: nil

  defp result_record({:ok, %Imp.Prediction{} = prediction}) do
    %{"status" => "typed", "prediction" => %{"status" => Imp.get(prediction, :status)}}
  end

  defp result_record({:error, reason}) do
    %{"status" => "error", "error" => safe_error(reason)}
  end

  defp result_record(other), do: %{"status" => "malformed", "error" => safe_error(other)}

  defp summarize(results) do
    passed = Enum.filter(results, &get_in(&1, ["format_status", "passed"]))

    %{
      "candidate_count" => length(results),
      "format_completed_count" => length(passed),
      "recommended_candidate" =>
        passed
        |> Enum.sort_by(&recommendation_key/1)
        |> List.first()
        |> then(&(&1 && get_in(&1, ["candidate", "id"]))),
      "optimizer_effectiveness_established" => false
    }
  end

  defp recommendation_key(result) do
    row = get_in(result, ["response_accounting", "responses"]) |> List.last()

    {
      if(get_in(result, ["format_status", "passed"]), do: 0, else: 1),
      if(row && row["finish_reason"] == "stop", do: 0, else: 1),
      (row && row["output_tokens"]) || 1_000_000,
      get_in(result, ["candidate", "max_output_tokens"])
    }
  end

  defp validate_manifest!(manifest) do
    candidates = manifest["candidates"] || []

    checks = [
      manifest["campaign_id"] == @campaign_id,
      manifest["status"] == "preregistered_not_run",
      get_in(manifest, ["synthetic_case", "signature"]) == @signature,
      get_in(manifest, ["synthetic_case", "instructions"]) == @instructions,
      get_in(manifest, ["synthetic_case", "input"]) == %{"code" => @input.code},
      get_in(manifest, ["synthetic_case", "expected"]) == %{"status" => "ok"},
      get_in(manifest, ["synthetic_case", "contains_support_ticket_material"]) == false,
      get_in(manifest, ["synthetic_case", "contains_benchmark_labels"]) == false,
      get_in(manifest, ["adapter", "response_format_mode"]) ==
        "explicit_strict_json_schema",
      get_in(manifest, ["adapter", "json_retries"]) == 0,
      get_in(manifest, ["execution", "max_calls_per_candidate"]) == 1,
      get_in(manifest, ["execution", "transport_retries"]) == 0,
      get_in(manifest, ["execution", "seed"]) == @seed,
      stringify(manifest["provider_guard"]) ==
        stringify(
          OpenRouterFreeGuard.provider_guard()
          |> Map.put(:usage_include, true)
          |> Map.put(:single_transport_attempt_per_logical_request, true)
        ),
      length(candidates) in 1..3,
      Enum.all?(candidates, &valid_candidate?/1)
    ]

    unless Enum.all?(checks), do: raise(ArgumentError, "typed-format canary manifest drifted")
    candidates
  end

  defp valid_candidate?(candidate) do
    is_binary(candidate["id"]) and String.ends_with?(candidate["id"], ":free") and
      is_integer(candidate["max_output_tokens"]) and candidate["max_output_tokens"] in 64..512 and
      candidate["reasoning_effort"] in [nil, "low"] and
      "response_format" in candidate["catalog_supported_parameters"]
  end

  defp receive_audit do
    receive do
      {:imp_typed_format_request_audit, audit} -> audit
    after
      0 -> nil
    end
  end

  defp parse_reasoning_effort(nil), do: nil
  defp parse_reasoning_effort("low"), do: :low

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_body(body) when is_map(body), do: body
  defp decode_body(_body), do: %{}

  defp map_value(nil, _key), do: nil
  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp map_value(_other, _key), do: nil

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp safe_error(error),
    do: error |> inspect(limit: 20, printable_limit: 500) |> Imp.Redaction.redact()

  defp elapsed_seconds(started),
    do: (System.monotonic_time(:millisecond) - started) / 1000.0

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end
