defmodule DSEx.Cache do
  @moduledoc """
  Small ETS-backed cache for DSEx's configurable cache concept.

  In normal production use the DSEx OTP application supervises the cache owner process.
  The ETS table is public for fast concurrent reads and writes, but its lifecycle
  belongs to that owner process. If the owner crashes, the table is recreated by
  the restarted process and cached values are intentionally lost. Calling cache
  functions before the application is started attempts to start the application.

  `fetch_or_store/2` is a best-effort cache helper, not a single-flight lock:
  concurrent misses for the same key may evaluate the supplied function more than
  once, and the last writer wins.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_opts) do
    create_table()
    Process.register(self(), __MODULE__)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  @doc """
  Ensures the cache owner and ETS table are available.

  Calling cache APIs before the `:dsex` application is started lazily starts the
  application when possible.
  """
  def configure(_opts \\ []) do
    ensure_table()
    :ok
  end

  @doc """
  Reads a cached value or returns `default`.

      iex> DSEx.Cache.put(:cache_doctest_get, :cached)
      :cached
      iex> DSEx.Cache.get(:cache_doctest_get)
      :cached
      iex> DSEx.Cache.get(:cache_doctest_missing, :fallback)
      :fallback

  """
  def get(key, default \\ nil) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  Stores a value and returns the stored value.

      iex> DSEx.Cache.put(:cache_doctest_put, %{answer: 42})
      %{answer: 42}

  """
  def put(key, value) do
    ensure_table()
    :ets.insert(@table, {key, value})
    value
  end

  @doc """
  Returns a cached value or computes, stores, and returns a miss.

  This helper is intentionally best-effort, not single-flight: concurrent misses
  may run the function more than once. Cache hit/miss telemetry is emitted with
  redacted metadata.

      iex> DSEx.Cache.clear()
      :ok
      iex> DSEx.Cache.fetch_or_store(:cache_doctest_fetch, fn -> :computed end)
      :computed
      iex> DSEx.Cache.fetch_or_store(:cache_doctest_fetch, fn -> :different end)
      :computed

  """
  def fetch_or_store(key, fun) when is_function(fun, 0) do
    case get(key, :__missing__) do
      :__missing__ ->
        DSEx.Telemetry.execute([:dsex, :cache, :miss], %{count: 1}, %{key: key})
        put(key, fun.())

      value ->
        DSEx.Telemetry.execute([:dsex, :cache, :hit], %{count: 1}, %{key: key})
        value
    end
  end

  def fetch_or_store(_key, fun) do
    raise ArgumentError,
          "DSEx.Cache.fetch_or_store/2 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc """
  Removes all cached values from the current ETS table.

  Cache contents are process-local operational state, not durable storage.
  """
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        ensure_owner_started()
        ensure_owner_table()

      _tid ->
        :ok
    end
  end

  defp ensure_owner_started do
    case Application.ensure_all_started(:dsex) do
      {:ok, _apps} -> :ok
      {:error, reason} -> handle_start_error(reason)
    end
  end

  defp ensure_owner_table do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(__MODULE__, :ensure_table)
      nil -> :ok
    end
  end

  defp create_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp start_unlinked do
    case GenServer.start(__MODULE__, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp handle_start_error(reason) do
    if Application.spec(:dsex) do
      raise "failed to start :dsex application for DSEx.Cache: #{inspect(reason)}"
    else
      start_unlinked()
    end
  end
end
