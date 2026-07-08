defmodule DSEx.Agent.Runtime do
  @moduledoc "Runtime sessions, context references, and traces for agents."

  defstruct context: %{},
            memory: %{},
            traces: [],
            event_sink: nil,
            redact_keys: DSEx.Redaction.default_keys()

  @option_schema [
    context: [type: :map, default: %{}],
    memory: [type: :map, default: %{}],
    traces: [type: {:list, :any}, default: []],
    event_sink: [type: :any],
    redact_keys: [type: {:list, :any}, default: DSEx.Redaction.default_keys()]
  ]

  def new(opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Agent.Runtime.new/1")
    validate_event_sink!(opts[:event_sink])

    %__MODULE__{
      context: opts[:context],
      memory: opts[:memory],
      traces: opts[:traces],
      event_sink: opts[:event_sink],
      redact_keys: opts[:redact_keys]
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
      |> DSEx.Redaction.redact(runtime.redact_keys)
      |> Map.put(:at, length(runtime.traces))

    emit(runtime.event_sink, event)
    %{runtime | traces: runtime.traces ++ [event]}
  end

  defp emit(nil, _event), do: :ok

  defp emit(sink, event) when is_function(sink, 1) do
    sink.(event)
    :ok
  rescue
    _exception -> :ok
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp validate_event_sink!(nil), do: :ok
  defp validate_event_sink!(event_sink) when is_function(event_sink, 1), do: :ok

  defp validate_event_sink!(event_sink) do
    raise ArgumentError,
          "DSEx.Agent.Runtime.new/1 expects :event_sink to be nil or an arity-1 function; got: #{inspect(event_sink)}"
  end

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
