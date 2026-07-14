defmodule RuntimeAsyncStreamCacheTest do
  use ExUnit.Case, async: false

  alias Imp.Streaming.Messages.StreamListener
  alias Imp.Streaming.Messages.StreamResponse

  setup do
    Imp.Cache.configure()
    Imp.Cache.clear()

    on_exit(fn ->
      Imp.Cache.configure()
      Imp.Cache.clear()
    end)

    :ok
  end

  test "cancels supervised tasks and removes them from the supervisor" do
    parent = self()

    task =
      Imp.Tasks.async_nolink(fn ->
        send(parent, {:started, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, pid}
    assert pid in Task.Supervisor.children(Imp.Tasks.unlinked_supervisor())
    assert Imp.Tasks.cancel(task, 1_000) == nil
    refute Process.alive?(pid)
    refute pid in Task.Supervisor.children(Imp.Tasks.unlinked_supervisor())
  end

  test "enforces TTL and reports synchronous cache usage" do
    assert :ok = Imp.Cache.configure(ttl: 10, max_entries: 10)
    assert Imp.Cache.put(:ttl_key, :value) == :value
    assert Imp.Cache.get(:ttl_key) == :value
    Process.sleep(15)
    assert Imp.Cache.get(:ttl_key, :expired) == :expired

    assert %{
             hits: 1,
             misses: 1,
             writes: 1,
             expirations: 1,
             size: 0,
             policy: %{enabled: true, ttl: 10, max_entries: 10}
           } = Imp.Cache.stats()
  end

  test "enforces capacity and supports disabled bypass policy" do
    Imp.Cache.configure(max_entries: 2)
    Imp.Cache.put(:one, 1)
    Process.sleep(2)
    Imp.Cache.put(:two, 2)
    Process.sleep(2)
    Imp.Cache.put(:three, 3)

    assert Imp.Cache.get(:one, :evicted) == :evicted
    assert Imp.Cache.get(:two) == 2
    assert Imp.Cache.get(:three) == 3
    assert Imp.Cache.stats().evictions == 1
    assert Imp.Cache.stats().size == 2

    Imp.Cache.configure(enabled: false)
    assert Imp.Cache.fetch_or_store(:disabled, fn -> :computed end) == :computed
    assert Imp.Cache.get(:disabled, :not_stored) == :not_stored
    assert Imp.Cache.stats().bypasses >= 3
  end

  test "stream listener observes events without changing final results or errors" do
    parent = self()
    listener = StreamListener.new(on_event: &send(parent, {:stream_event, &1}))

    events = [
      %StreamResponse{chunk: "partial"},
      %StreamResponse{chunk: {:error, :provider_failed}, done: true}
    ]

    assert StreamListener.attach(listener, events) |> Enum.to_list() == events
    assert_receive {:stream_event, %StreamResponse{chunk: "partial", done: false}}

    assert_receive {:stream_event, %StreamResponse{chunk: {:error, :provider_failed}, done: true}}
  end
end
