defmodule Imp.CacheSingleFlightTest do
  use ExUnit.Case, async: false

  import Imp.Test.TelemetryHelpers

  setup do
    Imp.Cache.configure()
    Imp.Cache.clear()

    on_exit(fn ->
      Imp.Cache.configure()
      Imp.Cache.clear()
    end)

    :ok
  end

  test "coalesces concurrent misses for one key without duplicate work" do
    caller_count = 24
    parent = self()

    telemetry_ref =
      attach([
        [:imp, :cache, :miss],
        [:imp, :cache, :coalesced]
      ])

    tasks =
      for _index <- 1..caller_count do
        Task.async(fn ->
          Imp.Cache.fetch_or_store(:shared_key, fn ->
            send(parent, {:computed, self()})

            receive do
              :release -> :shared_value
            end
          end)
        end)
      end

    assert_receive {:computed, producer}

    for _index <- 1..caller_count do
      assert_receive {^telemetry_ref, [:imp, :cache, :miss], %{count: 1}, %{key: :shared_key}}
    end

    wait_for_waiters(:shared_key, caller_count - 1)
    send(producer, :release)

    assert Enum.map(tasks, &Task.await(&1, 2_000)) ==
             List.duplicate(:shared_value, caller_count)

    refute_receive {:computed, _other_producer}

    for _index <- 1..(caller_count - 1) do
      assert_receive {^telemetry_ref, [:imp, :cache, :coalesced], %{count: 1, duration: duration},
                      %{key: :shared_key}}

      assert is_integer(duration) and duration >= 0
    end

    assert %{misses: ^caller_count, writes: 1, size: 1} = Imp.Cache.stats()
  end

  test "promotes one waiter when the producer is killed" do
    parent = self()

    telemetry_ref =
      attach([
        [:imp, :cache, :producer_down],
        [:imp, :cache, :retry]
      ])

    producer =
      Task.Supervisor.async_nolink(Imp.TaskSupervisor, fn ->
        Imp.Cache.fetch_or_store(:crash_key, fn ->
          send(parent, {:producer_started, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:producer_started, producer_pid}

    waiter =
      Task.Supervisor.async_nolink(Imp.TaskSupervisor, fn ->
        Imp.Cache.fetch_or_store(:crash_key, fn ->
          send(parent, {:waiter_promoted, self()})
          :recovered
        end)
      end)

    wait_for_waiters(:crash_key, 1)
    Process.exit(producer_pid, :kill)

    assert_receive {^telemetry_ref, [:imp, :cache, :producer_down], %{count: 1},
                    %{key: :crash_key, reason: :killed}}

    assert_receive {^telemetry_ref, [:imp, :cache, :retry], %{count: 1, duration: duration},
                    %{key: :crash_key, reason: :producer_down}}

    assert duration >= 0
    assert_receive {:waiter_promoted, waiter_pid}
    assert waiter_pid == waiter.pid
    assert {:exit, :killed} = Task.yield(producer, 1_000)
    assert Task.await(waiter, 2_000) == :recovered
    assert Imp.Cache.get(:crash_key) == :recovered
  end

  test "cached values cannot collide with the internal miss marker" do
    assert Imp.Cache.put(:sentinel_key, :__missing__) == :__missing__

    assert Imp.Cache.fetch_or_store(:sentinel_key, fn ->
             flunk("cached sentinel-like value was recomputed")
           end) == :__missing__
  end

  defp wait_for_waiters(key, count, attempts \\ 100)

  defp wait_for_waiters(key, count, attempts) when attempts > 0 do
    state = :sys.get_state(Imp.Cache)

    waiters = get_in(state, [:flights, key, :waiters])

    if waiters && :queue.len(waiters) == count do
      :ok
    else
      Process.sleep(5)
      wait_for_waiters(key, count, attempts - 1)
    end
  end

  defp wait_for_waiters(key, count, 0) do
    flunk("expected #{count} waiters for #{inspect(key)}")
  end
end
