defmodule Imp.BenchmarkTruth.HoverPapillonCalibration.PilotLM do
  @moduledoc false
  defstruct [:inner, :controller, :evidence, :budget, fail_on: []]

  def generate(%__MODULE__{} = lm, messages, opts) do
    opportunity = Imp.BenchmarkTruth.HoverPapillonCalibration.next_opportunity!(lm.controller)

    if is_nil(opportunity) do
      raise "provider-disabled execution exceeded active repetition schedule"
    end

    Imp.BenchmarkTruth.HoverPapillonCalibration.validate_stage_messages!(
      opportunity.stage,
      messages
    )

    Imp.BenchmarkTruth.HoverPapillonCalibration.pretransport_guard!(lm.budget, opportunity)

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

    usage = %{
      "input_tokens" => 11,
      "output_tokens" => 7,
      "cached_tokens" => 0,
      "total_tokens" => 18
    }

    Imp.BenchmarkTruth.HoverPapillonCalibration.record_actual_cost!(lm.budget, usage)

    event = %{
      "opportunity_id" => opportunity.id,
      "runtime" => opportunity.runtime,
      "task" => opportunity.task,
      "row" => opportunity.row,
      "repetition" => opportunity.repetition,
      "stage" => opportunity.stage,
      "model_requested" => Imp.BenchmarkTruth.HoverPapillonCalibration.model(),
      "model_effective" => Imp.BenchmarkTruth.HoverPapillonCalibration.model(),
      "provider" => "openai",
      "request_id" => "req-" <> String.replace(opportunity.id, "/", "-"),
      "timestamp_ns" => System.system_time(:nanosecond),
      "latency_us" => duration,
      "status" => status,
      "finish_reason" => "stop",
      "message_sha256" => wire.sha256,
      "message_bytes" => wire.bytes,
      "message_serialization" => wire.serialization,
      "max_input_bytes" => opportunity.max_input_bytes,
      "usage" => usage,
      "parse_status" => if(opportunity.id in lm.fail_on, do: "error", else: status),
      "error" =>
        if(status == "error", do: result |> Imp.Redaction.redact() |> inspect(), else: nil),
      "transport_count" => 1
    }

    Agent.update(lm.evidence, &[event | &1])
    Process.delete(:imp_calibration_opportunity)
    Process.delete(:imp_calibration_wire)
    result
  end
end
