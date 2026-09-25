defmodule OTPStateSemanticsTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    Application.ensure_all_started(:imp)
    Imp.Settings.reset()
    Imp.Cache.clear()

    on_exit(fn ->
      Application.ensure_all_started(:imp)
      Imp.Settings.reset()
      Imp.Cache.clear()
    end)

    :ok
  end

  test "application start owns settings cache and task supervisor processes" do
    assert Process.whereis(Imp.Settings)
    cache = Process.whereis(Imp.Cache)
    assert cache
    assert Process.whereis(Imp.TaskSupervisor)
    assert :ets.info(Imp.Cache, :owner) == cache
  end

  test "settings and cache APIs start the application for lazy library use" do
    :ok = Application.stop(:imp)
    refute Process.whereis(Imp.Settings)

    assert %{adapter: Imp.Adapter.Chat} = Imp.Settings.get()
    assert Process.whereis(Imp.Settings)
    assert Process.whereis(Imp.Cache)

    :ok = Application.stop(:imp)
    refute Process.whereis(Imp.Cache)

    assert Imp.Cache.put(:lazy_cache, :ok) == :ok
    assert Imp.Cache.get(:lazy_cache) == :ok
    assert :ets.info(Imp.Cache, :owner) == Process.whereis(Imp.Cache)
  end

  test "global settings are mutable while context overrides stay process-local" do
    Imp.configure(lm: :global)

    results =
      1..10
      |> Task.async_stream(fn index ->
        Imp.context([lm: {:local, index}], fn ->
          {Imp.settings().lm, parent_lm_from_child()}
        end)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.sort(Enum.map(results, &elem(&1, 0))) ==
             Enum.map(1..10, &{:local, &1})

    assert Enum.all?(results, &(elem(&1, 1) == :global))
    assert Imp.settings().lm == :global
  end

  test "settings contexts snapshot all effective values at entry" do
    Imp.configure(lm: :before, adapter: :before)
    parent = self()

    mutator =
      Task.async(fn ->
        receive do
          :mutate ->
            Imp.configure(lm: :after, adapter: :after, two_step_extraction_lm: :later)
            send(parent, :mutated)
        end
      end)

    captured =
      Imp.context([tenant: :outer], fn ->
        send(mutator.pid, :mutate)
        assert_receive :mutated

        Imp.context([request_id: :inner], fn ->
          Imp.settings()
        end)
      end)

    Task.await(mutator)
    assert captured.lm == :before
    assert captured.adapter == :before
    assert captured.tenant == :outer
    assert captured.request_id == :inner
    refute Map.has_key?(captured, :two_step_extraction_lm)
    assert Imp.settings().lm == :after
  end

  test "Imp tasks snapshot complete effective settings at submission" do
    Imp.configure(lm: :global_before, adapter: :before)
    parent = self()

    task =
      Imp.context([lm: :outer], fn ->
        Imp.context([tenant: :inner], fn ->
          Imp.Tasks.async_nolink(fn ->
            send(parent, {:snapshot_worker_ready, self()})

            receive do
              :read_snapshot ->
                base = Imp.settings()
                nested = Imp.context([tenant: :worker_nested], &Imp.settings/0)
                {base, nested}
            end
          end)
        end)
      end)

    assert_receive {:snapshot_worker_ready, worker_pid}
    Imp.configure(lm: :global_after, adapter: :after, two_step_extraction_lm: :later)
    send(worker_pid, :read_snapshot)

    assert {base, nested} = Task.await(task)
    assert base.lm == :outer
    assert base.adapter == :before
    assert base.tenant == :inner
    refute Map.has_key?(base, :two_step_extraction_lm)
    assert nested.tenant == :worker_nested
    assert nested.lm == :outer
    assert nested.adapter == :before
  end

  test "async_max_workers requires a positive integer" do
    assert_raise ArgumentError, ~r/:async_max_workers option: expected positive integer/, fn ->
      Imp.configure(async_max_workers: 0)
    end

    assert_raise ArgumentError, ~r/:async_max_workers option: expected positive integer/, fn ->
      Imp.context([async_max_workers: :many], fn -> :ok end)
    end
  end

  test "max_errors and retriever are not settings, and saying so names their place" do
    refute Map.has_key?(Imp.settings(), :max_errors)
    refute Map.has_key?(Imp.settings(), :retriever)

    for {key, place} <- [max_errors: ~r/to the optimizer/, retriever: ~r/Imp\.rag/] do
      assert_raise ArgumentError, ~r/#{inspect(key)} is not a setting/, fn ->
        Imp.configure([{key, 1}])
      end

      assert_raise ArgumentError, place, fn ->
        Imp.configure(%{Atom.to_string(key) => 1})
      end

      # context/2 carries keys of the caller's own, but not one that reads as
      # an Imp setting and would be ignored.
      assert_raise ArgumentError, ~r/#{inspect(key)} is not a setting/, fn ->
        Imp.context([{key, 1}], fn -> :ok end)
      end
    end
  end

  test "known string setting keys canonicalize safely and reject mixed-form collisions" do
    Imp.configure(%{"track_usage" => true, "async_max_workers" => 3})

    assert Imp.settings().track_usage == true
    assert Imp.settings().async_max_workers == 3
    refute Map.has_key?(Imp.settings(), "track_usage")
    refute Map.has_key?(Imp.settings(), "async_max_workers")

    assert Imp.context(%{"async_max_workers" => 2, "lm" => :string_lm}, fn ->
             {Imp.settings().async_max_workers, Imp.settings().lm}
           end) == {2, :string_lm}

    assert_raise ArgumentError, ~r/:async_max_workers option: expected positive integer/, fn ->
      Imp.configure(%{"async_max_workers" => -1})
    end

    colliding = Map.put(%{"async_max_workers" => 5}, :async_max_workers, 6)

    assert_raise ArgumentError, ~r/colliding setting keys/, fn ->
      Imp.configure(colliding)
    end

    unknown = "untrusted_setting_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert_raise ArgumentError, ~r/unknown settings/, fn ->
      Imp.configure(%{unknown => :refused})
    end

    refute Map.has_key?(Imp.settings(), unknown)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "supervisor restarts settings with defaults after a crash" do
    Imp.configure(lm: :temporary)
    old = Process.whereis(Imp.Settings)
    ref = Process.monitor(old)

    Process.exit(old, :kill)

    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = wait_until(fn -> restarted_pid(Imp.Settings, old) end)

    assert new != old
    assert Imp.settings().lm == nil
    assert Imp.settings().adapter == Imp.Adapter.Chat
  end

  test "cache table is recreated after owner crash and handles concurrent writes" do
    Imp.Cache.put(:restart_probe, :old)
    old = Process.whereis(Imp.Cache)
    ref = Process.monitor(old)

    Process.exit(old, :kill)

    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    new = wait_until(fn -> restarted_pid(Imp.Cache, old) end)

    assert new != old
    assert :ets.info(Imp.Cache, :owner) == new
    assert Imp.Cache.get(:restart_probe, :missing) == :missing

    values =
      1..50
      |> Task.async_stream(fn index ->
        Imp.Cache.put({:concurrent, index}, index)
      end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.sort(values) == Enum.to_list(1..50)
    assert Enum.map(1..50, &Imp.Cache.get({:concurrent, &1})) == Enum.to_list(1..50)
  end

  test "cache reports invalid fetch callbacks clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Cache\.fetch_or_store\/2 expects a zero-arity function/,
                 fn ->
                   Imp.Cache.fetch_or_store(:bad_callback, fn value -> value end)
                 end
  end

  defp parent_lm_from_child do
    Task.async(fn -> Imp.settings().lm end)
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
