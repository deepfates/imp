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

  # Starts a waiting run whose sink hands each event to `deliver` and reports
  # what it was given to the test. The run stops with the test process.
  defp start(deliver) do
    owner = self()

    sink = fn event ->
      deliver.(event)
      send(owner, {:stored, event})
    end

    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: owner}, event_sink: sink)
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
end
