defmodule Imp.RunObservationTest do
  use ExUnit.Case, async: true

  defmodule Wait do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_, %{owner: owner}) do
      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  test "trace excludes concurrent strangers and includes owned child tasks" do
    owner = self()

    stranger =
      spawn(fn ->
        receive do
          :go ->
            Imp.Telemetry.execute([:imp, :tool, :start], %{}, %{tool: :stranger})
            send(owner, :stranger_done)
        end
      end)

    trace =
      Imp.trace(fn ->
        send(stranger, :go)
        assert_receive :stranger_done

        task =
          Imp.Tasks.async(fn ->
            Imp.Telemetry.execute([:imp, :tool, :start], %{}, %{tool: :owned})
          end)

        Task.await(task)
      end)

    assert Enum.map(trace.events, fn {_, _, metadata} -> metadata.tool end) == [:owned]
  end

  test "cancel captures terminal record even when the sink is blocked" do
    owner = self()

    {:ok, run} =
      Imp.Run.start(%Wait{}, %{owner: owner}, event_sink: fn _ -> Process.sleep(:infinity) end)

    assert_receive :waiting
    assert {:ok, events} = Imp.Run.cancel_with_events(run, :host_cancelled, 100)
    assert Enum.map(events, & &1.kind) == [:run_started, :run_cancelled]
    assert List.last(events).error == :host_cancelled
    refute Process.alive?(run.control)
  end

  test "native event JSON retains booleans and redacts both maps in a pair" do
    event = %Imp.Run.Event{
      run_id: "r",
      sequence: 0,
      kind: :tool_result,
      output: [%{api_key: "sk-test-secret-1234567890"}, %{ok: true, missing: nil}]
    }

    map = Imp.Run.Event.to_map(event)
    assert map["output"] == [%{"api_key" => "[REDACTED]"}, %{"ok" => true, "missing" => nil}]
  end

  test "capture bounds are explicit and terminal evidence survives snapshot eviction" do
    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()}, max_events: 1, max_event_bytes: 1000)
    assert_receive :waiting

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:tool_result, output: String.duplicate("large", 1000))
    end)

    [gap, large] = Imp.Run.events(run)
    assert gap.kind == :capture_gap
    assert large.output == nil
    assert large.metadata.capture.truncated
    assert large.metadata.capture.original_bytes > 1000
    {:ok, [gap, terminal]} = Imp.Run.cancel_with_events(run)
    assert gap.metadata.dropped_events == 2
    assert terminal.kind == :run_cancelled
  end

  test "infinity capture keeps a megabyte tool result whole, in the sink and the snapshot" do
    owner = self()

    {:ok, run} =
      Imp.Run.start(%Wait{}, %{owner: owner},
        event_sink: fn event -> send(owner, {:sunk, event}) end,
        max_events: :infinity,
        max_event_bytes: :infinity,
        max_snapshot_bytes: :infinity
      )

    assert_receive :waiting
    payload = String.duplicate("lorem ipsum ", 90_000)
    assert byte_size(payload) > 1_000_000

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:tool_result, output: payload)
    end)

    assert_receive {:sunk, %{kind: :tool_result} = sunk}, 5_000
    assert sunk.output == payload
    refute Map.has_key?(sunk.metadata, :capture)

    assert [_started, retained] = Imp.Run.events(run)
    assert retained.output == payload
    Imp.Run.cancel(run)
  end

  test "an infinite event bound still truncates when a byte bound is set" do
    {:ok, run} =
      Imp.Run.start(%Wait{}, %{owner: self()}, max_events: :infinity, max_event_bytes: 1000)

    assert_receive :waiting

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:tool_result, output: String.duplicate("large", 1000))
    end)

    assert [_started, large] = Imp.Run.events(run)
    assert large.output == nil
    assert large.metadata.capture.truncated
    Imp.Run.cancel(run)
  end

  test "capture limits still reject anything that is neither a positive integer nor infinity" do
    for bad <- [[max_events: 0], [max_event_bytes: :unbounded], [max_snapshot_bytes: -1]] do
      error = assert_raise ArgumentError, fn -> Imp.Run.start(%Wait{}, %{owner: self()}, bad) end
      assert Exception.message(error) =~ "positive integer"
    end
  end

  test "oversized provider errors retain status without request or response content" do
    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()})
    assert_receive :waiting

    error =
      ReqLLM.Error.API.Request.exception(
        status: 429,
        reason: "private error explanation",
        request_body: String.duplicate("x", 215_000) <> "private request content",
        response_body: %{"message" => "private response content"},
        headers: %{"authorization" => "Bearer private-header-value"}
      )
      |> Map.put(:provider_code, "rate_limit_exceeded")
      |> Map.put(:retryable, true)

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:model_response, error: error, metadata: %{model_call_id: "fixture-call"})
    end)

    event = List.last(Imp.Run.events(run))

    assert event.error == %{
             truncated: true,
             status: 429,
             provider_code: "rate_limit_exceeded",
             retryable: true
           }

    assert event.metadata.model_call_id == "fixture-call"
    assert event.metadata.capture.truncated
    assert event.metadata.capture.original_bytes > 215_000
    assert :erlang.external_size(event) < 65_536

    serialized = event |> Imp.Run.Event.to_map() |> Jason.encode!()
    refute serialized =~ "private"
    refute serialized =~ "request_body"
    refute serialized =~ "response_body"
    refute serialized =~ "authorization"
    :ok = Imp.Run.cancel(run)
  end

  test "error summaries refuse arbitrary fields and unbounded provider codes" do
    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()}, max_event_bytes: 1000)
    assert_receive :waiting

    for error <- [
          %{status: "429", provider_code: String.duplicate("x", 2000), retryable: "true"},
          %{status: 999, provider_code: "sk-test-secret-1234567890", retryable: nil},
          %{status: -1, provider_code: "private words", retryable: %{private: "value"}},
          %{provider_code: "rate_limit\n"},
          {:provider_error, String.duplicate("private", 2000)}
        ] do
      Imp.Run.with_context(run.control, fn ->
        Imp.Run.emit(:model_response, error: error, input: String.duplicate("large", 1000))
      end)

      event = List.last(Imp.Run.events(run))
      assert event.error == %{truncated: true}
      assert :erlang.external_size(event) <= 1000
    end

    :ok = Imp.Run.cancel(run)
  end

  test "an error summary does not enlarge the existing capture envelope past a tight limit" do
    for limit <- [300, 400, 500, 600] do
      {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()}, max_event_bytes: limit)
      assert_receive :waiting

      Imp.Run.with_context(run.control, fn ->
        Imp.Run.emit(:model_response,
          error: %{status: 429, provider_code: String.duplicate("x", 64), retryable: true},
          input: String.duplicate("large", 1000)
        )
      end)

      event = List.last(Imp.Run.events(run))
      assert event.input == nil
      assert event.metadata.capture.truncated
      envelope_bytes = :erlang.external_size(%{event | error: nil})
      assert :erlang.external_size(event) <= max(limit, envelope_bytes)
      :ok = Imp.Run.cancel(run)
    end
  end

  test "ordinary errors and truncated successful responses keep their existing shape" do
    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()}, max_event_bytes: 1000)
    assert_receive :waiting

    Imp.Run.with_context(run.control, fn ->
      Imp.Run.emit(:model_response, error: %{status: 429, reason: "short fixture"})
      Imp.Run.emit(:model_response, output: String.duplicate("large", 1000))
    end)

    [_started, ordinary, large] = Imp.Run.events(run)
    assert ordinary.error == %{status: 429, reason: "short fixture"}
    refute Map.has_key?(ordinary.metadata, :capture)
    assert large.error == nil
    assert large.output == nil
    assert large.metadata.capture.truncated
    :ok = Imp.Run.cancel(run)
  end

  test "task death is recorded once by control even when the task cannot emit" do
    {:ok, run} = Imp.Run.start(%Wait{}, %{owner: self()})
    assert_receive :waiting
    Process.exit(run.task.pid, :kill)
    assert {:exit, :killed} = Task.yield(run.task, 1000)
    # A barrier on the monitor's signal is not implied by Task.yield to another process.
    wait_for_terminal(run, 100)
    events = Imp.Run.events(run)

    assert [%{kind: :run_failed, error: {:task_exit, :killed}}] =
             Enum.filter(events, &(&1.kind in [:run_failed, :run_finished, :run_cancelled]))

    Imp.Run.stop(run)
  end

  defp wait_for_terminal(run, left) when left > 0 do
    unless Enum.any?(Imp.Run.events(run), &(&1.kind == :run_failed)) do
      Process.sleep(1)
      wait_for_terminal(run, left - 1)
    end
  end

  defp wait_for_terminal(_, 0), do: flunk("run owner did not observe task death")
end
