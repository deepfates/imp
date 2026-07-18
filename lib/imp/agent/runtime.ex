defmodule Imp.Agent.Runtime do
  @moduledoc """
  Runtime sessions, context references, and traces for agents.

  Trace events are delivered to the optional `:event_sink`. A sink that raises,
  throws, or exits does not abort the agent run, but the failure is never
  silent: it is logged through `Imp.Observability.log/3` and emitted as an
  `[:imp, :agent, :event_sink, :exception]` telemetry event.
  """

  defstruct context: %{},
            memory: %{},
            traces: [],
            event_sink: nil,
            redact_keys: Imp.Redaction.default_keys()

  @option_schema [
    context: [type: :map, default: %{}],
    memory: [type: :map, default: %{}],
    traces: [type: {:list, :any}, default: []],
    event_sink: [
      type: {:custom, __MODULE__, :validate_event_sink, []}
    ],
    redact_keys: [
      type: {:custom, Imp.Redaction, :validate_keys, []},
      default: Imp.Redaction.default_keys()
    ]
  ]

  def new(opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Agent.Runtime.new/1")

    %__MODULE__{
      context: opts[:context],
      memory: opts[:memory],
      traces: opts[:traces],
      event_sink: opts[:event_sink],
      redact_keys: normalize_redact_keys(opts[:redact_keys])
    }
  end

  def put_context(%__MODULE__{} = runtime, key, value),
    do: %{runtime | context: Map.put(runtime.context, normalize_key(key), value)}

  def context_ref(%__MODULE__{} = runtime, key) do
    key = normalize_key(key)

    case Map.fetch(runtime.context, key) do
      {:ok, _value} -> {:ok, {:context_ref, key}}
      :error -> {:error, {:missing_context, key}}
    end
  end

  def resolve(%__MODULE__{} = runtime, {:context_ref, key}), do: Map.fetch(runtime.context, key)
  def resolve(_runtime, value), do: {:ok, value}

  def put_memory(%__MODULE__{} = runtime, key, value),
    do: %{runtime | memory: Map.put(runtime.memory, normalize_key(key), value)}

  def trace(%__MODULE__{} = runtime, event) do
    event =
      event
      |> Imp.Redaction.redact(runtime.redact_keys)
      |> Map.put(:at, length(runtime.traces))

    emit(runtime.event_sink, event)
    %{runtime | traces: runtime.traces ++ [event]}
  end

  defp emit(nil, _event), do: :ok

  defp emit(sink, event) when is_function(sink, 1) do
    sink.(event)
    :ok
  rescue
    exception -> surface_sink_failure(event, Exception.message(exception))
  catch
    kind, reason -> surface_sink_failure(event, inspect({kind, reason}))
  end

  # An event sink is an observer: a crashing sink must not abort the agent run,
  # but it must never fail invisibly. Surface the failure through Imp-scoped
  # logging and the `[:imp, :agent, :event_sink, :exception]` telemetry event
  # (same convention as `[:imp, :tool, :exception]`).
  defp surface_sink_failure(event, message) do
    Imp.Observability.log(
      :error,
      "Imp.Agent.Runtime event sink raised: #{message}",
      event_type: Map.get(event, :type)
    )

    Imp.Telemetry.execute(
      [:imp, :agent, :event_sink, :exception],
      %{},
      %{error: message, event: event}
    )

    :ok
  end

  def validate_event_sink(nil), do: {:ok, nil}
  def validate_event_sink(event_sink) when is_function(event_sink, 1), do: {:ok, event_sink}

  def validate_event_sink(event_sink) do
    {:error, "expected nil or an arity-1 function, got: #{inspect(event_sink)}"}
  end

  defp normalize_redact_keys(keys) do
    (Imp.Redaction.default_keys() ++ keys)
    |> Enum.uniq()
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
