defmodule Imp.Settings do
  @moduledoc """
  OTP-backed global settings with process-local overrides.

  The Imp OTP application owns the global settings process in normal production use.
  Calling this module before the application is started attempts to start the
  application, which gives the settings process the same supervision semantics as
  a regular OTP application. The global settings are intentionally mutable and
  node-local; use `context/2` for process-local overrides around a request,
  task, or test.
  """

  use Agent

  @name __MODULE__
  @defaults %{
    lm: nil,
    adapter: Imp.Adapter.Chat,
    retriever: nil,
    callbacks: [],
    async_max_workers: 8
  }
  @context_key :imp_context_stack
  @snapshot_key :imp_settings_snapshot
  @unset :imp_settings_unset

  def start_link(_opts), do: Agent.start_link(fn -> @defaults end, name: @name)

  @doc """
  Updates node-local Imp defaults.

  Use this for application-level defaults such as the LM client or adapter. For
  request, test, Livebook cell, or task-local overrides, prefer `context/2` so
  the override is restored automatically.
  """
  def configure(opts) when is_list(opts) or is_map(opts) do
    updates = normalize_settings(opts, "Imp.configure/1")
    ensure_started()
    Agent.update(@name, &Map.merge(&1, updates))
    :ok
  end

  def configure(opts) do
    raise ArgumentError,
          "Imp.configure/1 expects a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc """
  Returns the effective settings for the current process.

  Effective settings are the global defaults plus any nested `context/2`
  overrides in the current process.

      iex> Imp.Settings.context([lm: :local], fn -> Imp.Settings.get().lm end)
      :local

  """
  def get do
    base =
      case Process.get(@snapshot_key, @unset) do
        @unset ->
          ensure_started()
          Agent.get(@name, & &1)

        snapshot ->
          snapshot
      end

    @context_key
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.reduce(base, &Map.merge(&2, &1))
  end

  @doc """
  Fetches one effective setting or raises when the key is absent.

      iex> Imp.Settings.context([request_id: "req-1"], fn -> Imp.Settings.fetch!(:request_id) end)
      "req-1"

  """
  def fetch!(key), do: get() |> Map.fetch!(key)

  @doc """
  Restores global settings to Imp defaults.

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

  Each context snapshots all effective settings at entry, applies its overrides,
  and restores the previous snapshot even if the function raises. Child processes
  do not inherit process-local settings automatically; Imp-owned task helpers
  capture one complete effective snapshot when supervised async work is submitted.

      iex> Imp.Settings.context([lm: :outer], fn ->
      ...>   Imp.Settings.context([adapter: :inner], fn ->
      ...>     {Imp.Settings.get().lm, Imp.Settings.get().adapter}
      ...>   end)
      ...> end)
      {:outer, :inner}

      iex> parent = self()
      iex> Imp.Settings.context([lm: :parent_only], fn ->
      ...>   task = Task.async(fn -> send(parent, {:child_lm, Imp.Settings.get().lm}) end)
      ...>   Task.await(task)
      ...> end)
      iex> receive do
      ...>   {:child_lm, value} -> value
      ...> end
      nil

  """
  def context(opts, fun) when is_function(fun, 0) do
    settings =
      opts
      |> normalize_settings("Imp.context/2")
      |> then(&Map.merge(get(), &1))

    previous_snapshot = Process.get(@snapshot_key, @unset)
    previous_context = Process.get(@context_key, @unset)
    Process.put(@snapshot_key, settings)
    Process.put(@context_key, [])

    try do
      fun.()
    after
      restore_process_value(@snapshot_key, previous_snapshot)
      restore_process_value(@context_key, previous_context)
    end
  end

  def context(_opts, fun) when not is_function(fun, 0) do
    raise ArgumentError,
          "Imp.context/2 expects a zero-arity function; got: #{inspect(fun)}"
  end

  def context(opts, _fun) do
    raise ArgumentError,
          "Imp.context/2 expects settings as a map or settings pair list; got: #{inspect(opts)}"
  end

  @doc false
  def context_stack, do: Process.get(@context_key, [])

  @doc false
  def snapshot, do: get()

  @doc false
  def with_snapshot(snapshot, fun) when is_map(snapshot) and is_function(fun, 0) do
    previous_snapshot = Process.get(@snapshot_key, @unset)
    previous_context = Process.get(@context_key, @unset)
    Process.put(@snapshot_key, snapshot)
    Process.put(@context_key, [])

    try do
      fun.()
    after
      restore_process_value(@snapshot_key, previous_snapshot)
      restore_process_value(@context_key, previous_context)
    end
  end

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
    case Application.ensure_all_started(:imp) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        if Application.spec(:imp) do
          raise "failed to start :imp application for Imp.Settings: #{inspect(reason)}"
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
    settings
    |> Enum.reduce(%{}, fn
      {:async_max_workers, value}, normalized when is_integer(value) and value > 0 ->
        Map.put(normalized, :async_max_workers, value)

      {:async_max_workers, value}, _normalized ->
        raise ArgumentError,
              "#{context} expects :async_max_workers to be a positive integer; got: #{inspect(value)}"

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

  defp restore_process_value(key, @unset), do: Process.delete(key)
  defp restore_process_value(key, value), do: Process.put(key, value)
end
