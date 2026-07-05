defmodule DSPy.Cache do
  @moduledoc "Small ETS-backed cache compatible with DSPy's configurable cache concept."

  @table __MODULE__

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
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      _tid -> :ok
    end
  end
end
