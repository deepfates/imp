defmodule DSEx.Telemetry do
  @moduledoc "Small telemetry boundary for DSEx runtime events."

  def execute(event, measurements, metadata) do
    metadata = DSEx.Redaction.redact(metadata)

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    case Process.get(:dsex_telemetry_handler) do
      fun when is_function(fun, 3) -> fun.(event, measurements, metadata)
      _other -> :ok
    end

    :ok
  end

  def span(event_prefix, metadata, fun) when is_function(fun, 0) do
    started = System.monotonic_time()
    execute(event_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - started

      execute(
        event_prefix ++ [:stop],
        %{duration: duration},
        Map.put(metadata, :result, result_status(result))
      )

      result
    rescue
      error ->
        duration = System.monotonic_time() - started

        execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{error: Exception.message(error)})
        )

        reraise error, __STACKTRACE__
    end
  end

  defp result_status({:ok, _value}), do: :ok
  defp result_status({:error, _reason}), do: :error
  defp result_status(_value), do: :ok
end
