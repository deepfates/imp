defmodule Imp.Telemetry do
  @moduledoc """
  Small telemetry boundary for Imp runtime events.

  Imp telemetry metadata is redacted before it reaches `:telemetry`, so traces
  can stay useful without leaking provider credentials. `span/3` emits
  `event_prefix ++ [:start]`, then either `[:stop]` with a result status or
  `[:exception]` before re-raising the original failure.
  """

  @doc """
  Emits a redacted telemetry event when the optional `:telemetry` dependency is available.

      iex> Imp.Telemetry.execute([:imp, :example], %{count: 1}, %{api_key: "sk-test-secret-1234567890"})
      :ok

  """
  def execute(event, measurements, metadata) do
    metadata = Imp.Redaction.redact(metadata)

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  end

  @doc """
  Runs a zero-arity function inside start/stop/exception telemetry events.

      iex> Imp.Telemetry.span([:imp, :example], %{operation: :demo}, fn -> {:ok, 42} end)
      {:ok, 42}

  """
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
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        duration = System.monotonic_time() - started

        execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(metadata, %{error: error_message({kind, reason})})
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp result_status({:ok, _value}), do: :ok
  defp result_status({:error, _reason}), do: :error
  defp result_status(_value), do: :ok

  defp error_message({:throw, reason}), do: inspect({:throw, reason})
  defp error_message({:exit, reason}), do: inspect({:exit, reason})
  defp error_message({kind, reason}), do: inspect({kind, reason})
end
