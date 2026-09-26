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

  # Registers one cancellation per entry of `effects`, in order, and waits.
  # `:hang` never returns and reports its own process; `:killed` is ended by
  # an exit signal it cannot catch; `:returns` reports that it was called.
  defmodule Effects do
    @behaviour Imp.Module
    defstruct [:signature, :effects]

    def call(%{effects: effects}, %{owner: owner}) do
      effects
      |> Enum.with_index()
      |> Enum.each(fn {effect, index} ->
        Imp.Run.register_cancellable(fn reason ->
          send(owner, {:cancelling, index, self(), reason})
          if effect == :hang, do: Process.sleep(:infinity)
          if effect == :killed, do: Process.exit(self(), :kill)
        end)
      end)

      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  # When its first effect is cancelled, a process still working for the run
  # registers another, which never returns.
  defmodule LateEffect do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_, %{owner: owner}) do
      control = Imp.Run.context()

      worker =
        spawn(fn ->
          receive do
            :register ->
              Imp.Run.with_context(control, fn ->
                Imp.Run.register_cancellable(fn reason ->
                  send(owner, {:late_cancelled, reason})
                  Process.sleep(:infinity)
                end)
              end)
          end
        end)

      Imp.Run.register_cancellable(fn _reason -> send(worker, :register) end)
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
  # may or may not be stored, so it is a sink failure, and the ones queued
  # behind it were never handed over, so they are undelivered. Both are
  # reported, before `stop/1` returns.
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

    assert_received {:imp_run_event_undelivered, _run_id, %{sequence: 2, kind: :tool_call}}
    assert_received {:imp_run_event_undelivered, _run_id, %{sequence: 3, kind: :tool_result}}
    refute_received {:imp_run_event_sink_failed, _run_id, %{sequence: 0}}
    refute_received {:imp_run_event_sink_failed, _run_id, %{sequence: 2}}
    refute_received {:imp_run_event_undelivered, _run_id, %{sequence: 1}}
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
    assert_received {:imp_run_event_undelivered, _run_id, %{sequence: 2, kind: :run_cancelled}}
  end

  test "a run whose sink kept up reports nothing when stopped" do
    run = start(fn _event -> :ok end)
    emit(run, :model_response, output: "a")
    assert_receive {:stored, %Imp.Run.Event{kind: :model_response}}
    :ok = Imp.Run.stop(run)
    end_task(run)
    refute_received {:imp_run_event_sink_failed, _run_id, _failure}
    refute_received {:imp_run_event_undelivered, _run_id, _event}
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

    assert_received {:imp_run_event_undelivered, _run_id, %{sequence: 2, kind: :tool_call}}
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

  # The cancellations are called at once, so one that never returns keeps no
  # other from being called: an RLM's model call is ended by its own.
  test "every cancellation is called when another never returns" do
    {:ok, run} = Imp.Run.start(%Effects{effects: [:hang, :returns, :hang]}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting

    assert {:ok, _events} = Imp.Run.cancel_with_events(run, :host_cancelled, 200)
    assert_received {:cancelling, 1, _pid, :host_cancelled}

    # The two that never returned were abandoned at the deadline, not left.
    for index <- [0, 2] do
      assert_received {:cancelling, ^index, hung, :host_cancelled}
      monitor = Process.monitor(hung)
      assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
    end
  end

  # A cancellation process lives no longer than the control that waits for it,
  # however the control ends.
  test "a cancellation that never returns does not outlive a control that is killed" do
    {:ok, run} = Imp.Run.start(%Effects{effects: [:hang]}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting

    Process.exit(run.control, :shutdown)
    assert_receive {:cancelling, 0, cancelling, {:run_control_ended, :shutdown}}, 1_000
    Process.exit(run.control, :kill)

    monitor = Process.monitor(cancelling)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 1_000
  end

  # A cancellation registered after the cancel is called once, and a cancel
  # still returns within about twice its timeout when it never returns. The
  # registration races the cancel's release of the control: taken by the
  # control, it is called with the cancel's reason; arriving after, with the
  # control's end (the next test makes that case certain).
  test "a cancellation registered after the cancel neither holds the cancel nor is lost" do
    {:ok, run} = Imp.Run.start(%LateEffect{}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting

    started = System.monotonic_time(:millisecond)
    assert {:ok, _events} = Imp.Run.cancel_with_events(run, :host_cancelled, 200)
    elapsed = System.monotonic_time(:millisecond) - started

    assert_receive {:late_cancelled, reason}, 1_000
    assert reason in [:host_cancelled, {:run_control_ended, :noproc}]
    refute_receive {:late_cancelled, _reason}, 200
    assert elapsed < 1_000, "the cancel took #{elapsed} ms"
  end

  test "a cancellation registered after the control has ended is called, not lost" do
    {:ok, run} = Imp.Run.start(%Effects{effects: [:returns]}, %{owner: self()})
    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting
    assert {:ok, _events} = Imp.Run.cancel_with_events(run, :host_cancelled, 200)
    refute Process.alive?(run.control)

    owner = self()

    registered =
      Imp.Run.with_context(run.control, fn ->
        Imp.Run.register_cancellable(&send(owner, {:after_release, &1}))
      end)

    assert registered == nil
    assert_receive {:after_release, {:run_control_ended, :noproc}}, 1_000
  end

  # A cancellation's process can be ended by a signal no `catch` sees, the way
  # it would be by a process it linked to crashing. That is the cancellation's
  # failure, not the run's: the control goes on, and the cancel returns what
  # the run recorded.
  test "a cancellation killed outright does not take the control down" do
    {:ok, run} =
      Imp.Run.start(%Effects{effects: [:killed, :returns]}, %{owner: self()})

    on_exit(fn -> Process.exit(run.task.pid, :kill) end)
    assert_receive :waiting
    control = Process.monitor(run.control)

    assert {:ok, events} = Imp.Run.cancel_with_events(run, :host_cancelled, 1_000)
    assert List.last(events).kind == :run_cancelled
    assert_receive {:cancelling, 1, _pid, :host_cancelled}
    assert_receive {:DOWN, ^control, :process, _pid, :normal}, 1_000
  end
end
