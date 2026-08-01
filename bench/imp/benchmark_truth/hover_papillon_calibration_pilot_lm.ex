defmodule Imp.BenchmarkTruth.HoverPapillonCalibration.PilotLM do
  @moduledoc false
  defstruct [
    :inner,
    :controller,
    :evidence,
    :budget,
    :evidence_root,
    :mode,
    :api_key,
    :generation_fetch,
    :generation_sleep,
    :generation_attempts,
    fail_on: []
  ]

  alias Imp.BenchmarkTruth.HoverPapillonCalibration, as: Pilot

  def generate(%__MODULE__{} = lm, messages, opts) do
    opportunity = Pilot.next_opportunity!(lm.controller)

    if is_nil(opportunity) do
      raise "provider-disabled execution exceeded active repetition schedule"
    end

    Pilot.validate_stage_messages!(
      opportunity.stage,
      messages
    )

    Pilot.pretransport_guard!(lm.budget, opportunity)

    Process.put(:imp_calibration_opportunity, opportunity)
    started = System.monotonic_time(:microsecond)

    result =
      Imp.Clients.ReqLLM.generate(
        lm.inner,
        messages,
        Keyword.put(opts, :input_envelope,
          max_bytes: opportunity.max_input_bytes,
          reservation_tokens: opportunity.max_input_bytes
        )
      )

    Imp.OperationalSafetyError.raise_if_present!(result)

    duration = System.monotonic_time(:microsecond) - started
    wire = Process.get(:imp_calibration_wire) || raise "missing canonical wire evidence"
    status = if match?({:ok, _}, result), do: "ok", else: "error"
    injected_parse_failure? = opportunity.id in lm.fail_on
    event_status = if injected_parse_failure?, do: "error", else: status

    provider_response =
      Process.get(:imp_calibration_provider_response) ||
        raise Imp.OperationalSafetyError,
          kind: :transport,
          message: "missing provider response evidence"

    persist_provisional!(lm, opportunity, wire, provider_response, duration)
    validate_response_identity!(provider_response)
    metadata = response_metadata(result)
    response_usage = response_usage!(metadata, provider_response)
    validate_router_metadata!(provider_response["openrouter_metadata"])
    generation = generation_metadata!(lm, provider_response)
    usage = reconcile_usage!(response_usage, generation)
    Pilot.record_actual_cost!(lm.budget, usage)

    event = %{
      "opportunity_id" => opportunity.id,
      "runtime" => opportunity.runtime,
      "task" => opportunity.task,
      "row" => opportunity.row,
      "repetition" => opportunity.repetition,
      "stage" => opportunity.stage,
      "model_requested" => Pilot.model(),
      "model_response" => provider_response["model"],
      "model_effective" => generation["model"],
      "provider" => "openrouter",
      "upstream_provider" => generation["provider_name"],
      "endpoint_tag" => Pilot.endpoint_tag(),
      "request_id" => generation["request_id"],
      "generation_id" => provider_response["generation_id"],
      "timestamp_ns" => System.system_time(:nanosecond),
      "latency_us" => duration,
      "status" => event_status,
      "finish_reason" => provider_response["finish_reason"],
      "message_sha256" => wire.sha256,
      "message_bytes" => wire.bytes,
      "message_serialization" => wire.serialization,
      "max_input_bytes" => opportunity.max_input_bytes,
      "usage" => usage,
      "router_metadata" => provider_response["openrouter_metadata"],
      "parse_status" => event_status,
      "error" =>
        cond do
          injected_parse_failure? ->
            %{
              "type" => "AdapterParseError",
              "reason" => "redacted provider-disabled adapter failure"
            }

          status == "error" ->
            result |> Imp.Redaction.redact() |> inspect()

          true ->
            nil
        end,
      "transport_count" => 1
    }

    persist_reconciled!(lm, event)
    Agent.update(lm.evidence, &[event | &1])
    Process.delete(:imp_calibration_opportunity)
    Process.delete(:imp_calibration_wire)
    Process.delete(:imp_calibration_provider_response)
    result
  end

  defp response_metadata({:ok, raw}) do
    case Imp.LM.Result.split(raw) do
      {:ok, _output, %{req_llm: metadata}} when is_map(metadata) ->
        metadata

      {:ok, _output, %{"req_llm" => metadata}} when is_map(metadata) ->
        metadata

      other ->
        raise Imp.OperationalSafetyError,
          kind: :transport,
          message: "ReqLLM metadata missing",
          reason: other
    end
  end

  defp response_metadata({:error, reason}) do
    Imp.OperationalSafetyError.raise_if_present!(reason)
    %{}
  end

  defp generation_metadata!(%{generation_fetch: fetch} = lm, response)
       when is_function(fetch, 2) do
    opts =
      [
        fetch: fetch,
        sleep: lm.generation_sleep,
        attempts: lm.generation_attempts
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Pilot.generation_metadata!(response["generation_id"], lm.api_key, opts)
  end

  defp generation_metadata!(%{mode: :live, api_key: api_key}, response),
    do: Pilot.generation_metadata!(response["generation_id"], api_key)

  defp generation_metadata!(%{mode: :provider_disabled}, response) do
    usage = response["usage"]

    %{
      "id" => response["generation_id"],
      "model" => Pilot.endpoint_model(),
      "provider_name" => "Novita",
      "cancelled" => false,
      "session_id" => nil,
      "request_id" => "req-" <> response["generation_id"],
      "native_tokens_prompt" => usage["prompt_tokens"],
      "native_tokens_completion" => usage["completion_tokens"],
      "native_tokens_cached" => get_in(usage, ["prompt_tokens_details", "cached_tokens"]),
      "total_cost" => usage["cost"]
    }
  end

  defp response_usage!(metadata, response) do
    usage = metadata[:usage] || metadata["usage"] || %{}
    raw = response["usage"] || %{}
    details = raw["prompt_tokens_details"] || %{}

    # The raw OpenRouter response is the durable route evidence. ReqLLM's
    # normalized usage is checked when it contains concrete token counts, but
    # its defaults must never replace provider-reported values.
    input = raw["prompt_tokens"]
    output = raw["completion_tokens"]
    cached = details["cached_tokens"]
    total = raw["total_tokens"]
    # OpenRouter's response `usage.cost` is the route-attributable bill joined
    # to `/generation`. ReqLLM's normalized `:cost` is a component map and is
    # intentionally not substituted for that provider evidence.
    cost = raw["cost"]

    unless is_integer(input) and input >= 0 and is_integer(output) and output >= 0 and
             is_integer(cached) and cached >= 0 and cached <= input and is_integer(total) and
             total == input + output and is_number(cost) and cost >= 0 do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message: "OpenRouter usage metadata missing or inconsistent",
        reason: %{normalized: Imp.Redaction.redact(usage), raw: Imp.Redaction.redact(raw)}
    end

    crosscheck_normalized_usage!(usage, %{
      input_tokens: input,
      output_tokens: output,
      cached_tokens: cached,
      total_tokens: total
    })

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "cached_tokens" => cached,
      "total_tokens" => total,
      "provider_cost_usd" => cost
    }
  end

  defp crosscheck_normalized_usage!(normalized, expected) do
    Enum.each(expected, fn {key, provider_value} ->
      case map_value(normalized, key) do
        value when is_integer(value) and value >= 0 and value != provider_value ->
          raise Imp.OperationalSafetyError,
            kind: :cost,
            message: "ReqLLM normalized usage disagrees with OpenRouter response",
            reason: %{field: key, normalized: value, provider: provider_value}

        _ ->
          :ok
      end
    end)
  end

  defp validate_response_identity!(response) do
    unless response["model"] == Pilot.model() and response["provider"] == "Novita" and
             is_binary(response["generation_id"]) and response["generation_id"] != "" do
      raise Imp.OperationalSafetyError,
        kind: :route,
        message: "OpenRouter response route identity drift",
        reason:
          Imp.Redaction.redact(%{
            model: response["model"],
            provider: response["provider"],
            generation_id: response["generation_id"]
          })
    end

    :ok
  end

  defp reconcile_usage!(usage, generation) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]

    unless generation["native_tokens_prompt"] == input and
             generation["native_tokens_completion"] == output and
             generation["native_tokens_cached"] == usage["cached_tokens"] do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message: "OpenRouter generation usage disagrees with response usage",
        reason: %{response_input: input, response_output: output}
    end

    full_price = input / 1_000_000 * 0.14 + output / 1_000_000 * 0.28

    unless is_number(generation["total_cost"]) and
             abs(generation["total_cost"] - usage["provider_cost_usd"]) <= 1.0e-9 and
             generation["total_cost"] <= full_price + 1.0e-9 do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message: "OpenRouter response/generation cost join or full-price ceiling drift",
        reason: %{
          generation_cost: generation["total_cost"],
          response_cost: usage["provider_cost_usd"],
          full_price_ceiling: full_price
        }
    end

    usage
  end

  defp persist_provisional!(lm, opportunity, wire, response, duration) do
    value = %{
      "condition" => Pilot.condition(),
      "state" => "response_received_reconciliation_pending",
      "opportunity_id" => opportunity.id,
      "runtime" => opportunity.runtime,
      "task" => opportunity.task,
      "row" => opportunity.row,
      "repetition" => opportunity.repetition,
      "stage" => opportunity.stage,
      "generation_id" => response["generation_id"],
      "model_effective" => response["model"],
      "provider_reported" => response["provider"],
      "usage_reported" => response["usage"],
      "router_metadata" => response["openrouter_metadata"],
      "finish_reason" => response["finish_reason"],
      "message_sha256" => wire.sha256,
      "message_bytes" => wire.bytes,
      "message_serialization" => wire.serialization,
      "max_input_bytes" => opportunity.max_input_bytes,
      "latency_us" => duration,
      "timestamp_ns" => System.system_time(:nanosecond),
      "transport_count" => 1
    }

    Pilot.secure_write!(evidence_path(lm, "provisional", opportunity.id), value)
  end

  defp persist_reconciled!(lm, event) do
    Pilot.secure_write!(evidence_path(lm, "reconciled", event["opportunity_id"]), event)
  end

  defp evidence_path(%{evidence_root: root}, state, opportunity_id) do
    evidence_root = Path.join(root, "live-evidence")
    state_root = Path.join(evidence_root, state)
    File.mkdir_p!(state_root)
    File.chmod!(evidence_root, 0o700)
    File.chmod!(state_root, 0o700)
    filename = String.replace(opportunity_id, "/", "__") <> ".json"
    Path.join(state_root, filename)
  end

  defp validate_router_metadata!(%{
         "requested" => requested,
         "strategy" => "direct",
         "attempt" => 1,
         "endpoints" => %{"total" => total, "available" => available}
       })
       when is_integer(total) and total >= 1 and is_list(available) and length(available) == 1 do
    selected = Enum.filter(available, &(&1["selected"] == true))

    selected_endpoint = List.first(selected) || %{}

    unless requested == Pilot.model() and total >= length(available) and length(selected) == 1 and
             selected_endpoint["model"] == Pilot.endpoint_model() and
             selected_endpoint["provider"] == "Novita" do
      raise Imp.OperationalSafetyError,
        kind: :route,
        message: "OpenRouter routing metadata drift",
        reason: %{requested: requested, selected: selected}
    end

    :ok
  end

  defp validate_router_metadata!(other) do
    raise Imp.OperationalSafetyError,
      kind: :route,
      message: "OpenRouter routing metadata missing",
      reason: Imp.Redaction.redact(other)
  end

  defp map_value(map, key) when is_map(map), do: map[key] || map[to_string(key)]
  defp map_value(_map, _key), do: nil
end
