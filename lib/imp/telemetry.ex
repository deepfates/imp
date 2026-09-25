defmodule Imp.Telemetry do
  @moduledoc """
  Small telemetry boundary for Imp runtime events.

  Imp telemetry metadata is redacted before it reaches `:telemetry`, so traces
  can stay useful without leaking provider credentials. `span/3` emits
  `event_prefix ++ [:start]`, then either `[:stop]` with a result status or
  `[:exception]` before re-raising the original failure. The exception event's
  metadata carries `:kind`, `:reason` and `:stacktrace`, as `:telemetry.span/3`
  does: for a raise, `kind` is `:error` and `reason` the exception struct. Every span carries a
  stable `:call_id`; nested spans carry `:parent_call_id`, and ordinary events
  emitted inside a span inherit its `:call_id`.
  """

  @context_key :imp_telemetry_span_stack
  @acting_for_key :imp_telemetry_acting_for

  @doc false
  def execute(event, measurements, metadata) do
    measurements = Imp.Redaction.redact(measurements)
    metadata = metadata |> inherit_lineage() |> Imp.Redaction.redact()

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [event, measurements, metadata])
    end

    :ok
  end

  @doc false
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
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        duration = System.monotonic_time() - started

        execute(
          event_prefix ++ [:exception],
          %{duration: duration},
          Map.merge(span_metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
        )

        :erlang.raise(kind, reason, stacktrace)
    after
      restore_context(previous)
    end
  end

  @doc false
  # Makes the running process emit as `owner`: under `owner`'s span context,
  # and recognized by `emitted_for?/1`. For a process that exists only to make
  # one call for `owner`, such as the task ReqLLM runs a call with a
  # :total_timeout in (`Imp.Clients.ReqLLM`).
  def act_for(owner, context) when is_pid(owner) and is_list(context) do
    Process.put(@context_key, context)
    Process.put(@acting_for_key, owner)
    :ok
  end

  @doc false
  # Whether the running process is `owner`, or is acting for it. A handler that
  # keeps only its owner's events asks this rather than comparing `self()`:
  # other processes the owner started are still excluded.
  def emitted_for?(owner) when is_pid(owner),
    do: owner == self() or Process.get(@acting_for_key) == owner

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
end
