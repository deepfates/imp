defmodule Imp.Cache do
  @moduledoc """
  Small ETS-backed cache for Imp's configurable cache concept.

  In normal production use the Imp OTP application supervises the cache owner process.
  The ETS table is public for fast concurrent reads and writes, but its lifecycle
  belongs to that owner process. If the owner crashes, the table is recreated by
  the restarted process and cached values are intentionally lost. Calling cache
  functions before the application is started attempts to start the application.

  `fetch_or_store/2` coalesces concurrent misses per key. The first caller computes
  the value while other callers wait without blocking unrelated keys. Producers are
  monitored so a crash promotes one waiting caller and does not strand the rest.
  """

  use GenServer

  @table __MODULE__
  @usage_table Imp.Cache.Usage
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

    {:ok,
     %{
       policy: @default_policy,
       flights: %{},
       flight_refs: %{}
     }}
  end

  @doc """
  Ensures the cache owner and ETS table are available.

  Calling cache APIs before the `:imp` application is started lazily starts the
  application when possible.
  """
  def configure(opts \\ []) do
    ensure_table()
    opts = Imp.Options.validate!(opts, @policy_schema, "Imp.Cache.configure/1")
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

      iex> Imp.Cache.put(:cache_doctest_get, :cached)
      :cached
      iex> Imp.Cache.get(:cache_doctest_get)
      :cached
      iex> Imp.Cache.get(:cache_doctest_missing, :fallback)
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

      iex> Imp.Cache.put(:cache_doctest_put, %{answer: 42})
      %{answer: 42}

  """
  def put(key, value) do
    ensure_table()

    if active_policy().enabled do
      GenServer.call(__MODULE__, {:put, key, value}, :infinity)
    else
      increment_counter(:bypasses)
      value
    end
  end

  @doc """
  Returns a cached value or computes, stores, and returns a miss.

  Concurrent misses for the same key are coalesced into one computation. If that
  producer fails or exits, one waiting caller is promoted to compute the value.
  Cache hit, miss, coalesced-wait, retry, and producer-failure telemetry is emitted
  with redacted metadata.

      iex> Imp.Cache.clear()
      :ok
      iex> Imp.Cache.fetch_or_store(:cache_doctest_fetch, fn -> :computed end)
      :computed
      iex> Imp.Cache.fetch_or_store(:cache_doctest_fetch, fn -> :different end)
      :computed

  """
  def fetch_or_store(key, fun) when is_function(fun, 0) do
    missing = make_ref()

    case get(key, missing) do
      ^missing ->
        Imp.Telemetry.execute([:imp, :cache, :miss], %{count: 1}, %{key: key})
        fetch_miss(key, fun)

      value ->
        Imp.Telemetry.execute([:imp, :cache, :hit], %{count: 1}, %{key: key})
        value
    end
  end

  def fetch_or_store(_key, fun) do
    raise ArgumentError,
          "Imp.Cache.fetch_or_store/2 expects a zero-arity function, got: #{inspect(fun)}"
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
    enforce_capacity(policy.max_entries)
    state = %{state | policy: policy}
    {:reply, :ok, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    if state.policy.enabled do
      unless :ets.member(@table, key), do: make_room_for_insert(state.policy.max_entries)
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {key, value, expiry(now, state.policy.ttl), now})
      increment_counter(:writes)
    else
      increment_counter(:bypasses)
    end

    {:reply, value, state}
  end

  def handle_call({:claim_flight, key, caller}, from, state) do
    if state.policy.enabled do
      case cached_value(key) do
        {:ok, value} ->
          {:reply, {:ready, value}, state}

        :missing ->
          claim_missing_flight(key, caller, from, state)
      end
    else
      {:reply, :compute_untracked, state}
    end
  end

  def handle_call({:complete_flight, key, caller, value}, _from, state) do
    case state.flights[key] do
      %{owner: ^caller} = flight ->
        Enum.each(:queue.to_list(flight.waiters), fn {from, _pid, started_at} ->
          GenServer.reply(from, {:coalesced, value, started_at})
        end)

        {:reply, :ok, drop_flight(state, key, flight)}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:abandon_flight, key, caller}, _from, state) do
    case state.flights[key] do
      %{owner: ^caller} = flight ->
        {:reply, :ok, promote_waiter(state, key, flight, :producer_failed)}

      _other ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, owner, reason}, state) do
    case Map.fetch(state.flight_refs, monitor) do
      {:ok, key} ->
        case state.flights[key] do
          %{owner: ^owner, monitor: ^monitor} = flight ->
            Imp.Telemetry.execute(
              [:imp, :cache, :producer_down],
              %{count: 1},
              %{key: key, reason: exit_class(reason)}
            )

            {:noreply, promote_waiter(state, key, flight, :producer_down)}

          _other ->
            {:noreply, %{state | flight_refs: Map.delete(state.flight_refs, monitor)}}
        end

      :error ->
        {:noreply, state}
    end
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
    case Application.ensure_all_started(:imp) do
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

  defp fetch_miss(key, fun) do
    case GenServer.call(__MODULE__, {:claim_flight, key, self()}, :infinity) do
      :compute ->
        compute_flight(key, fun)

      :compute_untracked ->
        increment_counter(:bypasses)
        fun.()

      {:ready, value} ->
        value

      {:coalesced, value, started_at} ->
        emit_wait_event(:coalesced, key, started_at)
        value

      {:retry, started_at, reason} ->
        emit_wait_event(:retry, key, started_at, %{reason: reason})
        compute_flight(key, fun)
    end
  end

  defp compute_flight(key, fun) do
    started_at = System.monotonic_time()

    try do
      value = fun.()

      # Error tuples are delivered to coalesced waiters but never stored:
      # caching a transient failure forever would poison the key.
      unless match?({:error, _reason}, value), do: put(key, value)

      :ok = GenServer.call(__MODULE__, {:complete_flight, key, self(), value}, :infinity)
      value
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        abandon_flight(key)

        Imp.Telemetry.execute(
          [:imp, :cache, :producer_exception],
          %{count: 1, duration: System.monotonic_time() - started_at},
          %{key: key, kind: kind}
        )

        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp abandon_flight(key) do
    GenServer.call(__MODULE__, {:abandon_flight, key, self()}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  defp cached_value(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at, _inserted_at}] ->
        if expired?(expires_at) do
          :ets.delete(@table, key)
          :missing
        else
          {:ok, value}
        end

      [{^key, value}] ->
        {:ok, value}

      [] ->
        :missing
    end
  end

  defp claim_missing_flight(key, caller, from, state) do
    case state.flights[key] do
      %{owner: ^caller} ->
        {:reply, :compute_untracked, state}

      flight when is_map(flight) ->
        waiter = {from, caller, System.monotonic_time()}
        flight = %{flight | waiters: :queue.in(waiter, flight.waiters)}
        {:noreply, %{state | flights: Map.put(state.flights, key, flight)}}

      nil ->
        monitor = Process.monitor(caller)
        flight = %{owner: caller, monitor: monitor, waiters: :queue.new()}

        {:reply, :compute,
         %{
           state
           | flights: Map.put(state.flights, key, flight),
             flight_refs: Map.put(state.flight_refs, monitor, key)
         }}
    end
  end

  defp promote_waiter(state, key, flight, reason) do
    state = drop_flight(state, key, flight)
    promote_live_waiter(state, key, flight.waiters, reason)
  end

  defp promote_live_waiter(state, key, waiters, reason) do
    case :queue.out(waiters) do
      {{:value, {from, pid, started_at}}, remaining} ->
        if Process.alive?(pid) do
          monitor = Process.monitor(pid)
          flight = %{owner: pid, monitor: monitor, waiters: remaining}
          GenServer.reply(from, {:retry, started_at, reason})

          %{
            state
            | flights: Map.put(state.flights, key, flight),
              flight_refs: Map.put(state.flight_refs, monitor, key)
          }
        else
          promote_live_waiter(state, key, remaining, reason)
        end

      {:empty, _remaining} ->
        state
    end
  end

  defp drop_flight(state, key, flight) do
    Process.demonitor(flight.monitor, [:flush])

    %{
      state
      | flights: Map.delete(state.flights, key),
        flight_refs: Map.delete(state.flight_refs, flight.monitor)
    }
  end

  defp emit_wait_event(event, key, started_at, metadata \\ %{}) do
    Imp.Telemetry.execute(
      [:imp, :cache, event],
      %{count: 1, duration: System.monotonic_time() - started_at},
      Map.put(metadata, :key, key)
    )
  end

  defp exit_class(:normal), do: :normal
  defp exit_class(:killed), do: :killed
  defp exit_class(:shutdown), do: :shutdown
  defp exit_class({:shutdown, _reason}), do: :shutdown
  defp exit_class(_reason), do: :error

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

  # Both run only inside the cache owner process, so eviction is serialized:
  # no two writers race tab2list/sort/delete against each other, and a new
  # entry makes room BEFORE it is inserted, so the table never exceeds
  # max_entries at any observable instant.
  defp enforce_capacity(:infinity), do: :ok

  defp enforce_capacity(max_entries),
    do: evict_oldest(:ets.info(@table, :size) - max_entries)

  defp make_room_for_insert(:infinity), do: :ok

  defp make_room_for_insert(max_entries),
    do: evict_oldest(:ets.info(@table, :size) - max_entries + 1)

  defp evict_oldest(excess) when excess <= 0, do: :ok

  defp evict_oldest(excess) do
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

  defp start_unlinked do
    case GenServer.start(__MODULE__, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp handle_start_error(reason) do
    if Application.spec(:imp) do
      raise "failed to start :imp application for Imp.Cache: #{inspect(reason)}"
    else
      start_unlinked()
    end
  end
end
