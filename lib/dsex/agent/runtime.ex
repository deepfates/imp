defmodule DSEx.Agent.Runtime do
  @moduledoc "Runtime sessions, context references, and traces for agents."

  @default_redact_keys [:api_key, :authorization, :token, :password, :secret]

  defstruct context: %{},
            memory: %{},
            traces: [],
            event_sink: nil,
            redact_keys: @default_redact_keys

  def new(opts \\ []) do
    %__MODULE__{
      context: Keyword.get(opts, :context, %{}),
      memory: Keyword.get(opts, :memory, %{}),
      traces: Keyword.get(opts, :traces, []),
      event_sink: Keyword.get(opts, :event_sink),
      redact_keys: Keyword.get(opts, :redact_keys, @default_redact_keys)
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
      |> redact(runtime.redact_keys)
      |> Map.put(:at, length(runtime.traces))

    emit(runtime.event_sink, event)
    %{runtime | traces: runtime.traces ++ [event]}
  end

  defp redact(value, keys) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if redacted_key?(key, keys), do: {key, "[REDACTED]"}, else: {key, redact(nested, keys)}
    end)
  end

  defp redact(value, keys) when is_list(value), do: Enum.map(value, &redact(&1, keys))
  defp redact(value, _keys), do: value

  defp redacted_key?(key, keys) do
    normalized = key |> to_string() |> String.downcase()
    Enum.any?(keys, &(normalized == &1 |> to_string() |> String.downcase()))
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

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
