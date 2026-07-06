defmodule Dachshund.Settings do
  @moduledoc """
  OTP-backed global settings with process-local overrides.
  """

  use Agent

  @name __MODULE__
  @defaults %{lm: nil, adapter: Dachshund.Adapter.Chat, retriever: nil, callbacks: []}

  def start_link(_opts), do: Agent.start_link(fn -> @defaults end, name: @name)

  def configure(opts) when is_list(opts) or is_map(opts) do
    updates = Map.new(opts)
    ensure_started()
    Agent.update(@name, &Map.merge(&1, updates))
    :ok
  end

  def get do
    ensure_started()
    global = Agent.get(@name, & &1)
    Map.merge(global, Process.get(:Dachshund_context, %{}))
  end

  def fetch!(key), do: get() |> Map.fetch!(key)

  def context(opts, fun) when is_function(fun, 0) do
    previous = Process.get(:Dachshund_context, %{})
    Process.put(:Dachshund_context, Map.merge(previous, Map.new(opts)))

    try do
      fun.()
    after
      Process.put(:Dachshund_context, previous)
    end
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> {:ok, _pid} = start_link([])
      _pid -> :ok
    end
  end
end
