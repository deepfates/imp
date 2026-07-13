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
  @usage_table DSEx.Cache.Usage
  @policy_key {__MODULE__, :policy}

  @default_policy %{enabled: true, ttl: :infinity, max_entries: :infinity}
  @empty_usage %{hits: 0, misses: 0, writes: 0, bypasses: 0, expirations: 0, evictions: 0}
  @policy_schema [
    enabled: [type: :boolean, default: true],
    ttl: [type: {:or, [{:in, [:infinity]}, :pos_integer]}, default: :infinity],
    max_entries: [type: {:or, [{:in, [:infinity]}, :pos_integer]}, default: :infinity]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

  @impl true
  def init(_opts) do
    create_table()
    :persistent_term.put(@policy_key, @default_policy)
    Process.register(self(), __MODULE__)
    {:ok, %{policy: @default_policy, usage: @empty_usage}}
  end

  @doc """
  Ensures the cache owner and ETS table are available.

  Calling cache APIs before the `:dsex` application is started lazily starts the
  application when possible.
  """
  def configure(opts \\ []) do
    ensure_table()
    opts = DSEx.Options.validate!(opts, @policy_schema, "DSEx.Cache.configure/1")
    GenServer.call(__MODULE__, {:configure, Map.new(opts)})
  end

  @doc "Returns the active cache policy."
  def policy do
    ensure_table()
    active_policy()
  end

  @doc "Returns cache usage counters and current entry count."
  def stats do
    ensure_table()

    @empty_usage
    |> Map.new(fn {counter, _zero} -> {counter, usage_counter(counter)} end)
    |> Map.merge(%{size: :ets.info(@table, :size), policy: active_policy()})
  end

  @doc "Resets cache usage counters without removing entries."
  def reset_stats do
    ensure_table()
    reset_usage_counters()
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

    if active_policy().enabled do
      case :ets.lookup(@table, key) do
        [{^key, value, expires_at, _inserted_at}] ->
          if expired?(expires_at) do
            :ets.delete(@table, key)
            increment_counter(:misses)
            increment_counter(:expirations)
            default
          else
            increment_counter(:hits)
            value
          end

        [{^key, value}] ->
          increment_counter(:hits)
          value

        [] ->
          increment_counter(:misses)
          default
      end
    else
      increment_counter(:bypasses)
      default
    end
  end

  @doc """
  Stores a value and returns the stored value.

      iex> DSEx.Cache.put(:cache_doctest_put, %{answer: 42})
      %{answer: 42}

  """
  def put(key, value) do
    ensure_table()
    policy = active_policy()

    if policy.enabled do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {key, value, expiry(now, policy.ttl), now})
      increment_counter(:writes)
      enforce_capacity_direct(policy.max_entries)
    else
      increment_counter(:bypasses)
    end

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
    reset_usage_counters()
    :ok
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  def handle_call({:configure, policy}, _from, state) do
    :persistent_term.put(@policy_key, policy)
    enforce_capacity_direct(policy.max_entries)
    state = %{state | policy: policy}
    {:reply, :ok, state}
  end

  def handle_call(:policy, _from, state), do: {:reply, state.policy, state}

  def handle_call(:stats, _from, state) do
    {:reply, Map.merge(state.usage, %{size: :ets.info(@table, :size), policy: state.policy}),
     state}
  end

  def handle_call(:reset_stats, _from, state),
    do: {:reply, reset_stats(), %{state | usage: @empty_usage}}

  def handle_call({:get, _key, default}, _from, %{policy: %{enabled: false}} = state) do
    {:reply, default, increment(state, :bypasses)}
  end

  def handle_call({:get, key, default}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _inserted_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table, key)
          {:reply, default, state |> increment(:misses) |> increment(:expirations)}
        else
          {:reply, value, increment(state, :hits)}
        end

      [{^key, value}] ->
        {:reply, value, increment(state, :hits)}

      [] ->
        {:reply, default, increment(state, :misses)}
    end
  end

  def handle_call({:put, _key, value}, _from, %{policy: %{enabled: false}} = state) do
    {:reply, value, increment(state, :bypasses)}
  end

  def handle_call({:put, key, value}, _from, state) do
    now = System.monotonic_time(:millisecond)
    expires_at = expiry(now, state.policy.ttl)
    :ets.insert(@table, {key, value, expires_at, now})
    state = state |> increment(:writes) |> enforce_capacity()
    {:reply, value, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | usage: @empty_usage}}
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

    if :ets.whereis(@usage_table) == :undefined do
      :ets.new(@usage_table, [:named_table, :public, write_concurrency: true])
      reset_usage_counters()
    end

    :ok
  end

  defp expiry(_now, :infinity), do: :infinity
  defp expiry(now, ttl), do: now + ttl

  defp expired?(:infinity), do: false
  defp expired?(expires_at), do: expires_at <= System.monotonic_time(:millisecond)

  defp increment(state, counter, amount \\ 1) do
    update_in(state, [:usage, counter], &(&1 + amount))
  end

  defp active_policy, do: :persistent_term.get(@policy_key, @default_policy)

  defp increment_counter(counter, amount \\ 1),
    do: :ets.update_counter(@usage_table, counter, amount, {counter, 0})

  defp usage_counter(counter) do
    case :ets.lookup(@usage_table, counter) do
      [{^counter, value}] -> value
      [] -> 0
    end
  end

  defp reset_usage_counters do
    :ets.delete_all_objects(@usage_table)
    :ets.insert(@usage_table, Map.to_list(@empty_usage))
  end

  defp enforce_capacity_direct(:infinity), do: :ok

  defp enforce_capacity_direct(max_entries) do
    excess = max(:ets.info(@table, :size) - max_entries, 0)

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(fn
      {_key, _value, _expires_at, inserted_at} -> inserted_at
      {_key, _value} -> System.monotonic_time(:millisecond)
    end)
    |> Enum.take(excess)
    |> Enum.each(fn entry ->
      :ets.delete(@table, elem(entry, 0))
      increment_counter(:evictions)
    end)
  end

  defp enforce_capacity(%{policy: %{max_entries: :infinity}} = state), do: state

  defp enforce_capacity(%{policy: %{max_entries: max_entries}} = state) do
    excess = max(:ets.info(@table, :size) - max_entries, 0)

    evicted =
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn
        {_key, _value, _expires_at, inserted_at} -> inserted_at
        {_key, _value} -> System.monotonic_time(:millisecond)
      end)
      |> Enum.take(excess)

    Enum.each(evicted, fn entry -> :ets.delete(@table, elem(entry, 0)) end)
    increment(state, :evictions, length(evicted))
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
