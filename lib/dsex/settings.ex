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

  @doc """
  Updates node-local DSEx defaults.

  Use this for application-level defaults such as the LM client or adapter. For
  request, test, Livebook cell, or task-local overrides, prefer `context/2` so
  the override is restored automatically.
  """
  def configure(opts) when is_list(opts) or is_map(opts) do
    updates = normalize_settings(opts, "DSEx.configure/1")
    ensure_started()
    Agent.update(@name, &Map.merge(&1, updates))
    :ok
  end

  def configure(opts) do
    raise ArgumentError,
          "DSEx.configure/1 expects a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc """
  Returns the effective settings for the current process.

  Effective settings are the global defaults plus any nested `context/2`
  overrides in the current process.

      iex> DSEx.Settings.context([lm: :local], fn -> DSEx.Settings.get().lm end)
      :local

  """
  def get do
    ensure_started()
    global = Agent.get(@name, & &1)

    @context_key
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.reduce(global, &Map.merge(&2, &1))
  end

  @doc """
  Fetches one effective setting or raises when the key is absent.

      iex> DSEx.Settings.context([request_id: "req-1"], fn -> DSEx.Settings.fetch!(:request_id) end)
      "req-1"

  """
  def fetch!(key), do: get() |> Map.fetch!(key)

  @doc """
  Restores global settings to DSEx defaults.

  Process-local `context/2` overrides are not global state and are restored by
  the context call itself.
  """
  def reset do
    ensure_started()
    Agent.update(@name, fn _settings -> @defaults end)
    :ok
  end

  @doc """
  Runs a zero-arity function with process-local settings overrides.

  Overrides are stack-based and restored even if the function raises. Child
  processes do not inherit ordinary process-local settings automatically; use
  DSEx-owned task helpers when you want context propagation through supervised
  async work.

      iex> DSEx.Settings.context([lm: :outer], fn ->
      ...>   DSEx.Settings.context([adapter: :inner], fn ->
      ...>     {DSEx.Settings.get().lm, DSEx.Settings.get().adapter}
      ...>   end)
      ...> end)
      {:outer, :inner}

      iex> parent = self()
      iex> DSEx.Settings.context([lm: :parent_only], fn ->
      ...>   task = Task.async(fn -> send(parent, {:child_lm, DSEx.Settings.get().lm}) end)
      ...>   Task.await(task)
      ...> end)
      iex> receive do
      ...>   {:child_lm, value} -> value
      ...> end
      nil

  """
  def context(opts, fun) when is_function(fun, 0) do
    settings = normalize_settings(opts, "DSEx.context/2")
    previous = Process.get(@context_key, [])
    Process.put(@context_key, [settings | previous])

    try do
      fun.()
    after
      Process.put(@context_key, previous)
    end
  end

  def context(_opts, fun) when not is_function(fun, 0) do
    raise ArgumentError,
          "DSEx.context/2 expects a zero-arity function; got: #{inspect(fun)}"
  end

  def context(opts, _fun) do
    raise ArgumentError,
          "DSEx.context/2 expects settings as a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc false
  def context_stack, do: Process.get(@context_key, [])

  @doc false
  def with_context_stack(stack, fun) when is_list(stack) and is_function(fun, 0) do
    previous = Process.get(@context_key, [])
    Process.put(@context_key, stack)

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

      {:error, reason} ->
        if Application.spec(:dsex) do
          raise "failed to start :dsex application for DSEx.Settings: #{inspect(reason)}"
        else
          start_unlinked()
        end
    end
  end

  defp start_unlinked do
    case Agent.start(fn -> @defaults end, name: @name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp normalize_settings(settings, context) when is_list(settings) or is_map(settings) do
    Enum.reduce(settings, %{}, fn
      {key, value}, normalized ->
        Map.put(normalized, key, value)

      invalid_entry, _normalized ->
        raise ArgumentError,
              "#{context} expects settings as {key, value} pairs; got entry: #{inspect(invalid_entry)}"
    end)
  end

  defp normalize_settings(settings, context) do
    raise ArgumentError,
          "#{context} expects settings as a map or settings pair list; got: #{inspect(settings)}"
  end
end
