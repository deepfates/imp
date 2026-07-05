defmodule DSPy.Cache do
  @moduledoc "Small ETS-backed cache compatible with DSPy's configurable cache concept."

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
      :__missing__ -> put(key, fun.())
      value -> value
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
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _tid ->
        :ok
    end
  end
end
