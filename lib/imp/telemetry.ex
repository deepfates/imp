defmodule Imp.Telemetry do
  @moduledoc """
  Small telemetry boundary for Imp runtime events.

  Imp telemetry metadata is redacted before it reaches `:telemetry`, so traces
  can stay useful without leaking provider credentials. `span/3` emits
  `event_prefix ++ [:start]`, then either `[:stop]` with a result status or
  `[:exception]` before re-raising the original failure. Every span carries a
  stable `:call_id`; nested spans carry `:parent_call_id`, and ordinary events
  emitted inside a span inherit its `:call_id`.
  """

  @context_key :imp_telemetry_span_stack

  @doc """
  Emits a redacted telemetry event when the optional `:telemetry` dependency is available.

      iex> Imp.Telemetry.execute([:imp, :example], %{count: 1}, %{api_key: "sk-test-secret-1234567890"})
      :ok

  """
  def execute(event, measurements, metadata) do
    measurements = Imp.Redaction.redact(measurements)
    metadata = metadata |> inherit_lineage() |> Imp.Redaction.redact()

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
    previous = context()
    parent_call_id = current_call_id(previous)
    lineage = %{call_id: new_call_id(), parent_call_id: parent_call_id}
    span_metadata = Map.merge(metadata, lineage)
    execute(event_prefix ++ [:start], %{system_time: System.system_time()}, span_metadata)
    Process.put(@context_key, [lineage | previous])

    try do
      result = fun.()
      duration = System.monotonic_time() - started

      execute(
        event_prefix ++ [:stop],
        %{duration: duration},
        Map.put(span_metadata, :result, result_status(result))
      )

      result
    rescue
      error ->
        duration = System.monotonic_time() - started

        execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(span_metadata, %{error: Exception.message(error)})
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        duration = System.monotonic_time() - started

        execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(span_metadata, %{error: error_message({kind, reason})})
        )

        :erlang.raise(kind, reason, stacktrace)
    after
      restore_context(previous)
    end
  end

  @doc false
  def context, do: Process.get(@context_key, [])

  @doc false
  def with_context(context, fun) when is_list(context) and is_function(fun, 0) do
    previous = Process.get(@context_key, :unset)
    Process.put(@context_key, context)

    try do
      fun.()
    after
      case previous do
        :unset -> Process.delete(@context_key)
        value -> Process.put(@context_key, value)
      end
    end
  end

  @doc false
  def with_trace(id, fun) when is_binary(id) and is_function(fun, 0) do
    with_context([%{trace_id: id} | context()], fun)
  end

  defp inherit_lineage(metadata) do
    trace_id = Enum.find_value(context(), &Map.get(&1, :trace_id))
    metadata = if trace_id, do: Map.put(metadata, :trace_id, trace_id), else: metadata

    case current_call_id(context()) do
      nil -> metadata
      call_id -> Map.put_new(metadata, :call_id, call_id)
    end
  end

  defp current_call_id(context), do: Enum.find_value(context, &Map.get(&1, :call_id))

  defp new_call_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp restore_context([]), do: Process.delete(@context_key)
  defp restore_context(previous), do: Process.put(@context_key, previous)

  defp result_status({:ok, _value}), do: :ok
  defp result_status({:error, _reason}), do: :error
  defp result_status(_value), do: :ok

  defp error_message({:throw, reason}), do: inspect({:throw, reason})
  defp error_message({:exit, reason}), do: inspect({:exit, reason})
  defp error_message({kind, reason}), do: inspect({kind, reason})
end
