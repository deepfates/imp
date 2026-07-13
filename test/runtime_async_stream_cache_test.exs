defmodule RuntimeAsyncStreamCacheTest do
  use ExUnit.Case, async: false

  alias DSEx.Streaming.Messages.StreamListener
  alias DSEx.Streaming.Messages.StreamResponse

  setup do
    DSEx.Cache.configure()
    DSEx.Cache.clear()

    on_exit(fn ->
      DSEx.Cache.configure()
      DSEx.Cache.clear()
    end)

    :ok
  end

  test "cancels supervised tasks and removes them from the supervisor" do
    parent = self()

    task =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, {:started, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, pid}
    assert pid in Task.Supervisor.children(DSEx.Tasks.unlinked_supervisor())
    assert DSEx.Tasks.cancel(task, 1_000) == nil
    refute Process.alive?(pid)
    refute pid in Task.Supervisor.children(DSEx.Tasks.unlinked_supervisor())
  end

  test "enforces TTL and reports synchronous cache usage" do
    assert :ok = DSEx.Cache.configure(ttl: 10, max_entries: 10)
    assert DSEx.Cache.put(:ttl_key, :value) == :value
    assert DSEx.Cache.get(:ttl_key) == :value
    Process.sleep(15)
    assert DSEx.Cache.get(:ttl_key, :expired) == :expired

    assert %{
             hits: 1,
             misses: 1,
             writes: 1,
             expirations: 1,
             size: 0,
             policy: %{enabled: true, ttl: 10, max_entries: 10}
           } = DSEx.Cache.stats()
  end

  test "enforces capacity and supports disabled bypass policy" do
    DSEx.Cache.configure(max_entries: 2)
    DSEx.Cache.put(:one, 1)
    Process.sleep(2)
    DSEx.Cache.put(:two, 2)
    Process.sleep(2)
    DSEx.Cache.put(:three, 3)

    assert DSEx.Cache.get(:one, :evicted) == :evicted
    assert DSEx.Cache.get(:two) == 2
    assert DSEx.Cache.get(:three) == 3
    assert DSEx.Cache.stats().evictions == 1
    assert DSEx.Cache.stats().size == 2

    DSEx.Cache.configure(enabled: false)
    assert DSEx.Cache.fetch_or_store(:disabled, fn -> :computed end) == :computed
    assert DSEx.Cache.get(:disabled, :not_stored) == :not_stored
    assert DSEx.Cache.stats().bypasses >= 3
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
