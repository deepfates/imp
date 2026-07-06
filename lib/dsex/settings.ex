defmodule DSEx.Settings do
  @moduledoc """
  OTP-backed global settings with process-local overrides.

  The DSEx OTP application owns the global settings process in normal production use.
  Calling this module before the application is started attempts to start the
  application, which gives the settings process the same supervision semantics as
  a regular OTP application. The global settings are intentionally mutable and
  node-local; use `context/2` for process-local overrides around a request,
  task, or test.
  """

  use Agent

  @name __MODULE__
  @defaults %{lm: nil, adapter: DSEx.Adapter.Chat, retriever: nil, callbacks: []}
  @context_key :dsex_context_stack

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

    @context_key
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.reduce(global, &Map.merge(&2, &1))
  end

  def fetch!(key), do: get() |> Map.fetch!(key)

  def reset do
    ensure_started()
    Agent.update(@name, fn _settings -> @defaults end)
    :ok
  end

  def context(opts, fun) when is_function(fun, 0) do
    previous = Process.get(@context_key, [])
    Process.put(@context_key, [Map.new(opts) | previous])

    try do
      fun.()
    after
      Process.put(@context_key, previous)
    end
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil -> start_application_or_agent()
      _pid -> :ok
    end
  end

  defp start_application_or_agent do
    case Application.ensure_all_started(:dsex) do
      {:ok, _apps} ->
        :ok

      {:error, _reason} ->
        start_unlinked()
    end
  end

  defp start_unlinked do
    case Agent.start(fn -> @defaults end, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
