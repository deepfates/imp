defmodule DSEx.Tracking.SessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DSEx.Tracking.Session

  defmodule FirstBackend do
    @behaviour DSEx.Tracking.Backend

    @impl true
    def start(opts) do
      send(opts[:test_pid], {:tracking, :first, :start})
      {:ok, opts[:test_pid]}
    end

    @impl true
    def log(owner, event) do
      send(owner, {:tracking, :first, :log, event})
      :ok
    end

    @impl true
    def finish(owner, status) do
      send(owner, {:tracking, :first, :finish, status})
      :ok
    end
  end

  defmodule SecondBackend do
    @behaviour DSEx.Tracking.Backend

    @impl true
    def start(opts) do
      send(opts[:test_pid], {:tracking, :second, :start, opts[:backend_value]})
      {:ok, opts[:test_pid]}
    end

    @impl true
    def log(owner, event) do
      send(owner, {:tracking, :second, :log, event})
      {:error, :log_unavailable}
    end

    @impl true
    def finish(owner, status) do
      send(owner, {:tracking, :second, :finish, status})
      {:error, :finish_unavailable}
    end
  end

  defmodule FailingStartBackend do
    @behaviour DSEx.Tracking.Backend

    @impl true
    def start(opts) do
      send(opts[:test_pid], {:tracking, :failing, :start})
      {:error, :credentials_rejected}
    end

    @impl true
    def log(_state, _event), do: :ok

    @impl true
    def finish(_state, _status), do: :ok
  end

  test "fans out in order and warns without stopping on log or finish errors" do
    assert {:ok, session} =
             Session.start(
               [FirstBackend, {SecondBackend, backend_value: 42}],
               test_pid: self()
             )

    assert_receive {:tracking, :first, :start}
    assert_receive {:tracking, :second, :start, 42}

    log =
      capture_log(fn ->
        assert :ok = Session.log(session, {:metrics, %{score: 1.0}})
        assert_receive {:tracking, :first, :log, {:metrics, %{score: 1.0}}}
        assert_receive {:tracking, :second, :log, {:metrics, %{score: 1.0}}}

        assert :ok = Session.finish(session, :finished)
        assert_receive {:tracking, :first, :finish, :finished}
        assert_receive {:tracking, :second, :finish, :finished}
      end)

    assert log =~ "SecondBackend log failed"
    assert log =~ "SecondBackend finish failed"
  end

  test "a start failure is fatal and rolls back already-started backends" do
    assert {:error, {:backend_start_failed, FailingStartBackend, :credentials_rejected}} =
             Session.start([FirstBackend, FailingStartBackend], test_pid: self())

    assert_receive {:tracking, :first, :start}
    assert_receive {:tracking, :failing, :start}
    assert_receive {:tracking, :first, :finish, :failed}
  end

  test "only the owning process may use a session" do
    assert {:ok, session} = Session.start([FirstBackend], test_pid: self())
    assert_receive {:tracking, :first, :start}

    assert {:error, {:not_session_owner, owner, caller}} =
             Task.async(fn -> Session.log(session, :event) end) |> Task.await()

    assert owner == self()
    refute caller == self()
    refute_receive {:tracking, :first, :log, :event}
  end
end
