defmodule DSPy.Agent.Runtime do
  @moduledoc "Runtime sessions, context references, and traces for agents."

  defstruct context: %{}, memory: %{}, traces: []

  def new(opts \\ []) do
    %__MODULE__{
      context: Keyword.get(opts, :context, %{}),
      memory: Keyword.get(opts, :memory, %{}),
      traces: Keyword.get(opts, :traces, [])
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

  def trace(%__MODULE__{} = runtime, event),
    do: %{runtime | traces: runtime.traces ++ [Map.put(event, :at, length(runtime.traces))]}

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)
end
