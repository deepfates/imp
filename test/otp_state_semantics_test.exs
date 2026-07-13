defmodule OTPStateSemanticsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    Application.ensure_all_started(:dsex)
    DSEx.Settings.reset()
    DSEx.Cache.clear()

    on_exit(fn ->
      Application.ensure_all_started(:dsex)
      DSEx.Settings.reset()
      DSEx.Cache.clear()
    end)

    :ok
  end

  test "application start owns settings cache and task supervisor processes" do
    assert Process.whereis(DSEx.Settings)
    cache = Process.whereis(DSEx.Cache)
    assert cache
    assert Process.whereis(DSEx.TaskSupervisor)
    assert :ets.info(DSEx.Cache, :owner) == cache
  end

  test "settings and cache APIs start the application for lazy library use" do
    :ok = Application.stop(:dsex)
    refute Process.whereis(DSEx.Settings)

    assert %{adapter: DSEx.Adapter.Chat} = DSEx.Settings.get()
    assert Process.whereis(DSEx.Settings)
    assert Process.whereis(DSEx.Cache)

    :ok = Application.stop(:dsex)
    refute Process.whereis(DSEx.Cache)

    assert DSEx.Cache.put(:lazy_cache, :ok) == :ok
    assert DSEx.Cache.get(:lazy_cache) == :ok
    assert :ets.info(DSEx.Cache, :owner) == Process.whereis(DSEx.Cache)
  end

  test "global settings are mutable while context overrides stay process-local" do
    DSEx.configure(lm: :global)

    results =
      1..10
      |> Task.async_stream(fn index ->
        DSEx.context([lm: {:local, index}], fn ->
          {DSEx.settings().lm, parent_lm_from_child()}
        end)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(Enum.map(results, &elem(&1, 0))) ==
             Enum.map(1..10, &{:local, &1})

    assert Enum.all?(results, &(elem(&1, 1) == :global))
    assert DSEx.settings().lm == :global
  end

  test "settings contexts snapshot all effective values at entry" do
    DSEx.configure(lm: :before, callbacks: [:before])
    parent = self()

    mutator =
      Task.async(fn ->
        receive do
          :mutate ->
            DSEx.configure(lm: :after, callbacks: [:after], added_later: true)
            send(parent, :mutated)
        end
      end)

    captured =
      DSEx.context([tenant: :outer], fn ->
        send(mutator.pid, :mutate)
        assert_receive :mutated

        DSEx.context([request_id: :inner], fn ->
          DSEx.settings()
        end)
      end)

    Task.await(mutator)
    assert captured.lm == :before
    assert captured.callbacks == [:before]
    assert captured.tenant == :outer
    assert captured.request_id == :inner
    refute Map.has_key?(captured, :added_later)
    assert DSEx.settings().lm == :after
  end

  test "DSEx tasks snapshot complete effective settings at submission" do
    DSEx.configure(lm: :global_before, callbacks: [:before], stable: :before)
    parent = self()

    task =
      DSEx.context([lm: :outer], fn ->
        DSEx.context([tenant: :inner], fn ->
          DSEx.Tasks.async_nolink(fn ->
            send(parent, {:snapshot_worker_ready, self()})

            receive do
              :read_snapshot ->
                base = DSEx.settings()
                nested = DSEx.context([tenant: :worker_nested], &DSEx.settings/0)
                {base, nested}
            end
          end)
        end)
      end)

    assert_receive {:snapshot_worker_ready, worker_pid}
    DSEx.configure(lm: :global_after, callbacks: [:after], stable: :after, added_later: true)
    send(worker_pid, :read_snapshot)

    assert {base, nested} = Task.await(task)
    assert base.lm == :outer
    assert base.callbacks == [:before]
    assert base.stable == :before
    assert base.tenant == :inner
    refute Map.has_key?(base, :added_later)
    assert nested.tenant == :worker_nested
    assert nested.lm == :outer
    assert nested.callbacks == [:before]
  end

  test "async_max_workers requires a positive integer" do
    assert_raise ArgumentError, ~r/:async_max_workers to be a positive integer/, fn ->
      DSEx.configure(async_max_workers: 0)
    end

    assert_raise ArgumentError, ~r/:async_max_workers to be a positive integer/, fn ->
      DSEx.context([async_max_workers: :many], fn -> :ok end)
    end
  end

  test "supervisor restarts settings with defaults after a crash" do
    DSEx.configure(lm: :temporary)
    old = Process.whereis(DSEx.Settings)
    ref = Process.monitor(old)

    Process.exit(old, :kill)

    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = wait_until(fn -> restarted_pid(DSEx.Settings, old) end)

    assert new != old
    assert DSEx.settings().lm == nil
    assert DSEx.settings().adapter == DSEx.Adapter.Chat
  end

  test "cache table is recreated after owner crash and handles concurrent writes" do
    DSEx.Cache.put(:restart_probe, :old)
    old = Process.whereis(DSEx.Cache)
    ref = Process.monitor(old)

    Process.exit(old, :kill)

    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = wait_until(fn -> restarted_pid(DSEx.Cache, old) end)

    assert new != old
    assert :ets.info(DSEx.Cache, :owner) == new
    assert DSEx.Cache.get(:restart_probe, :missing) == :missing

    values =
      1..50
      |> Task.async_stream(fn index ->
        DSEx.Cache.put({:concurrent, index}, index)
      end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.sort(values) == Enum.to_list(1..50)
    assert Enum.map(1..50, &DSEx.Cache.get({:concurrent, &1})) == Enum.to_list(1..50)
  end

  test "cache reports invalid fetch callbacks clearly" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Cache\.fetch_or_store\/2 expects a zero-arity function/,
                 fn ->
                   DSEx.Cache.fetch_or_store(:bad_callback, fn value -> value end)
                 end
  end

  defp parent_lm_from_child do
    Task.async(fn -> DSEx.settings().lm end)
    |> Task.await()
  end

  defp restarted_pid(module, old) do
    case Process.whereis(module) do
      pid when is_pid(pid) and pid != old -> pid
      _other -> false
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      false ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(_fun, 0), do: flunk("timed out waiting for supervised process restart")
end
