defmodule Imp.RunEventSinkFailureTest do
  # A sink that raises, throws or exits may not have stored the event it was
  # given. The run's owner is told which event, and delivery goes on.
  use ExUnit.Case, async: true

  defmodule Wait do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_, %{owner: owner}) do
      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  # A program with an effect in flight: it registers how to cancel it, the way
  # a tool call does, and waits. With `cancel: :hang` the cancellation never
  # returns, as one waiting on an unresponsive client would not.
  defmodule InFlight do
    @behaviour Imp.Module
    defstruct [:signature, cancel: :returns]

    def call(%{cancel: cancel}, %{owner: owner}) do
      Imp.Run.register_cancellable(fn reason ->
        send(owner, {:effect_cancelled, reason})
        if cancel == :hang, do: Process.sleep(:infinity)
      end)

      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  # Starts a waiting run whose sink hands each event to `deliver` and reports
  # what it was given to the test. The run stops with the test process.
  defp start(deliver) do
    owner = self()

    sink = fn event ->
      deliver.(event)
      send(owner, {:stored, event})
    end

    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: owner}, event_sink: sink)
    # End the task whatever the test did, so a failing test does not leave
    # it holding a place in Imp's task pool.
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting
    run
  end

  defp emit(run, kind, attrs),
    do: Imp.Run.with_context(run.control, fn -> Imp.Run.emit(kind, attrs) end)

  test "a sink that raises is reported to the owner, and delivery goes on" do
    run =
      start(fn
        %{kind: :model_response} -> raise "store refused"
        _event -> :ok
      end)

    emit(run, :model_response, output: "answer")
    emit(run, :tool_call, tool_name: :lookup)

    assert_receive {:imp_run_event_sink_failed, run_id,
                    %{sequence: 1, kind: :model_response, reason: {:error, %RuntimeError{}}}}

    assert run_id == run.id
    assert_receive {:stored, %Imp.Run.Event{kind: :tool_call, sequence: 2}}

    # The event is still in the run's own snapshot.
    assert Enum.any?(Imp.Run.events(run), &(&1.sequence == 1 and &1.kind == :model_response))
  end

  test "a sink whose store call exits is reported" do
    run =
      start(fn
        %{kind: :tool_result} -> exit({:timeout, {GenServer, :call, [:store, :append, 5_000]}})
        _event -> :ok
      end)

    emit(run, :tool_result, output: "x")

    assert_receive {:imp_run_event_sink_failed, _run_id,
                    %{sequence: 1, kind: :tool_result, reason: {:exit, {:timeout, _call}}}}
  end

  test "a sink that throws is reported" do
    run =
      start(fn
        %{kind: :tool_call} -> throw(:full)
        _event -> :ok
      end)

    emit(run, :tool_call, tool_name: :lookup)

    assert_receive {:imp_run_event_sink_failed, _run_id,
                    %{kind: :tool_call, reason: {:throw, :full}}}
  end

  test "a sink that fails on every event is reported once for each, in order" do
    run =
      start(fn
        %{kind: :run_started} -> :ok
        _event -> exit(:store_down)
      end)

    emit(run, :model_response, output: "a")
    emit(run, :model_response, output: "b")

    assert_receive {:imp_run_event_sink_failed, _run_id, %{sequence: 1}}
    assert_receive {:imp_run_event_sink_failed, _run_id, %{sequence: 2}}
    refute_receive {:imp_run_event_sink_failed, _run_id, _failure}, 100
  end

  # A guard against false reports; it passes on a build without reporting too.
  test "a sink that stores every event sends the owner nothing" do
    run = start(fn _event -> :ok end)
    emit(run, :model_response, output: "a")
    assert_receive {:stored, %Imp.Run.Event{kind: :model_response}}
    refute_receive {:imp_run_event_sink_failed, _run_id, _failure}, 100
  end

  # A sink that is still holding an event when the run is stopped: that event
  # may or may not be stored, and the ones queued behind it were never handed
  # over. Both are reported, before `stop/1` returns.
  @tag timeout: 20_000
  test "stopping a run reports the event in the sink and every event never handed to it" do
    owner = self()

    run =
      start(fn
        %{kind: :model_response} ->
          send(owner, :holding)
          receive(do: (:never -> :ok))

        _event ->
          :ok
      end)

    emit(run, :model_response, output: "a")
    emit(run, :tool_call, tool_name: :lookup)
    emit(run, :tool_result, output: "b")
    assert_receive :holding

    :ok = Imp.Run.stop(run)
    end_task(run)

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 1, kind: :model_response, reason: :in_sink_when_stopped}}

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 2, kind: :tool_call, reason: :never_handed_to_sink}}

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 3, kind: :tool_result, reason: :never_handed_to_sink}}

    refute_received {:imp_run_event_sink_failed, _run_id, %{sequence: 0}}
  end

  test "cancelling a run reports the events it cut off" do
    owner = self()

    run =
      start(fn
        %{kind: :model_response} ->
          send(owner, :holding)
          receive(do: (:never -> :ok))

        _event ->
          :ok
      end)

    emit(run, :model_response, output: "a")
    assert_receive :holding

    {:ok, _events} = Imp.Run.cancel_with_events(run, :host_cancelled, 100)

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 1, reason: :in_sink_when_stopped}}

    # The run_cancelled event recorded at cancel was never handed over.
    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 2, kind: :run_cancelled, reason: :never_handed_to_sink}}
  end

  test "a run whose sink kept up reports nothing when stopped" do
    run = start(fn _event -> :ok end)
    emit(run, :model_response, output: "a")
    assert_receive {:stored, %Imp.Run.Event{kind: :model_response}}
    :ok = Imp.Run.stop(run)
    end_task(run)
    refute_received {:imp_run_event_sink_failed, _run_id, _failure}
  end

  # The sink's process can die outright, not just raise: here the sink is
  # linked to a process that exits. The event it held and the ones queued
  # behind it are reported all the same.
  test "a sink whose process is killed reports what it had not finished" do
    owner = self()

    run =
      start(fn
        %{kind: :model_response} ->
          send(owner, :holding)
          receive(do: (:go -> spawn_link(fn -> exit(:store_crashed) end)))
          receive(do: (:never -> :ok))

        _event ->
          :ok
      end)

    emit(run, :model_response, output: "a")
    emit(run, :tool_call, tool_name: :lookup)
    assert_receive :holding

    monitor = Process.monitor(run.control)
    send(:sys.get_state(run.control).delivery, :go)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
    end_task(run)

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 1, kind: :model_response, reason: :in_sink_when_stopped}}

    assert_received {:imp_run_event_sink_failed, _run_id,
                     %{sequence: 2, kind: :tool_call, reason: :never_handed_to_sink}}
  end

  # Waits for the task to be gone, so it holds no place in Imp's task pool
  # after the test.
  defp end_task(run) do
    monitor = Process.monitor(run.task.pid)
    Process.exit(run.task.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
  end

  # The control owns the run. When its sink's process dies the control ends,
  # and the run must not go on without it: the effect in flight is cancelled
  # and the task ends, instead of running on until it next emits an event.
  test "a run whose control ends because its sink died does not outlive it" do
    owner = self()

    sink = fn
      %{kind: :run_started} ->
        send(owner, {:sink, self()})
        receive(do: (:die -> spawn_link(fn -> exit(:store_crashed) end)))
        receive(do: (:never -> :ok))

      _event ->
        :ok
    end

    {:ok, run} = Imp.Run.start(%InFlight{}, %{owner: owner}, event_sink: sink)
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting
    assert_receive {:sink, delivery}

    task = Process.monitor(run.task.pid)
    control = Process.monitor(run.control)
    send(delivery, :die)

    assert_receive {:DOWN, ^control, :process, _pid, _reason}, 5_000
    assert_receive {:effect_cancelled, {:run_control_ended, _reason}}, 5_000
    assert_receive {:DOWN, ^task, :process, _pid, _reason}, 5_000
  end

  # Ending the task waits on the cancellations only so long: one that never
  # returns must not leave the run going on without its control.
  test "a run whose control ends is ended even when a cancellation never returns" do
    {:ok, run} = Imp.Run.start(%InFlight{cancel: :hang}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting

    task = Process.monitor(run.task.pid)
    Process.exit(run.control, :shutdown)

    assert_receive {:effect_cancelled, {:run_control_ended, :shutdown}}, 5_000
    assert_receive {:DOWN, ^task, :process, _pid, :killed}, 8_000
  end

  # A cancel waits for the cancellations no longer than its timeout: one that
  # never returns neither keeps the task going nor keeps `cancel/3` from
  # returning.
  test "a cancel ends the task and returns in time when a cancellation never returns" do
    {:ok, run} = Imp.Run.start(%InFlight{cancel: :hang}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting

    task = Process.monitor(run.task.pid)
    cancel = Task.async(fn -> Imp.Run.cancel_with_events(run, :host_cancelled, 200) end)

    assert_receive {:effect_cancelled, :host_cancelled}, 1_000
    assert_receive {:DOWN, ^task, :process, _pid, _reason}, 1_000
    assert {:ok, {:ok, events}} = Task.yield(cancel, 2_000)
    assert List.last(events).kind == :run_cancelled
  end
end
