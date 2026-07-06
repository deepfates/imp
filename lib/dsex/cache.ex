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

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, %{}}
  end

  def configure(_opts \\ []) do
    ensure_table()
    :ok
  end

  def get(key, default \\ nil) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  def put(key, value) do
    ensure_table()
    :ets.insert(@table, {key, value})
    value
  end

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

  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        case Application.ensure_all_started(:dsex) do
          {:ok, _apps} -> :ok
          {:error, reason} -> handle_start_error(reason)
        end

      _tid ->
        :ok
    end
  end

  defp start_unlinked do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
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
