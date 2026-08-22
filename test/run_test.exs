defmodule Imp.RunTest do
  use ExUnit.Case, async: true

  defmodule NestedProgram do
    @behaviour Imp.Module
    defstruct [:signature]

    @impl true
    def call(_program, _inputs) do
      task = Imp.Tasks.async(fn -> Imp.Run.emit(:nested, output: "child") end)
      :ok = Task.await(task)
      {:ok, Imp.Prediction.new(%{answer: "done"})}
    end
  end

  defmodule BlockingProgram do
    @behaviour Imp.Module
    defstruct [:signature]

    @impl true
    def call(_program, _inputs) do
      Process.sleep(:infinity)
      {:ok, Imp.Prediction.new(%{answer: "late"})}
    end
  end

  test "ReActV2 emits ordered source IDs, reasoning, tool calls, results, and final output" do
    owner = self()
    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found " <> query end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "look it up",
            tool_calls: [
              %{id: "provider-call-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "provider-submit-1", name: "submit", arguments: %{answer: "BEAM"}}
            ]
          }
        end
      )

    program = Imp.react_v2("question -> answer", [lookup], lm: lm)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "runtime?"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, prediction} = Task.await(run.task)
    assert Imp.get(prediction, :answer) == "BEAM"
    :ok = Imp.Run.stop(run)

    events = receive_events([])
    assert Enum.map(events, & &1.sequence) == Enum.to_list(0..7)

    assert [
             %{kind: :run_started},
             %{kind: :reasoning, reasoning: "look it up"},
             %{kind: :tool_call, tool_call_id: "provider-call-1", tool_name: "lookup"},
             %{kind: :tool_result, tool_call_id: "provider-call-1", output: "found beam"},
             %{kind: :tool_call, tool_call_id: "provider-submit-1", tool_name: "submit"},
             %{kind: :tool_result, tool_call_id: "provider-submit-1"},
             %{kind: :final},
             %{kind: :run_finished}
           ] = events
  end

  test "cancelling an RLM run cancels its registered in-flight LM effect before returning" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, {:effect_started, self()})
          Process.sleep(:infinity)
        end
      )

    program = Imp.rlm("question -> answer", lm: lm)
    assert {:ok, run} = Imp.Run.start(program, %{question: "wait"})
    assert_receive {:effect_started, effect_pid}, 1_000
    monitor = Process.monitor(effect_pid)

    assert :ok = Imp.cancel_run(run, :host_cancelled, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^effect_pid, :killed}, 1_000
    refute Process.alive?(run.task.pid)
    refute Process.alive?(run.control)
  end

  test "supervised child tasks inherit the active run event context" do
    owner = self()
    program = %NestedProgram{signature: Imp.signature("question -> answer")}

    assert {:ok, run} =
             Imp.Run.start(program, %{question: "nested"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, _prediction} = Task.await(run.task)
    :ok = Imp.Run.stop(run)

    assert Enum.any?(receive_events([]), &(&1.kind == :nested and &1.output == "child"))
  end

  test "an owner crash cannot orphan its unlinked outer run" do
    test_pid = self()

    owner =
      spawn(fn ->
        program = %Imp.RunTest.BlockingProgram{signature: Imp.signature("question -> answer")}
        {:ok, run} = Imp.Run.start(program, %{question: "wait"})
        send(test_pid, {:owned_run, run})

        receive do
          :crash -> exit(:owner_crashed)
        end
      end)

    assert_receive {:owned_run, run}
    task_monitor = Process.monitor(run.task.pid)
    send(owner, :crash)

    assert_receive {:DOWN, ^task_monitor, :process, _pid, :killed}, 1_000
    refute Process.alive?(run.control)
  end

  defp receive_events(events) do
    receive do
      {:run_event, event} -> receive_events(events ++ [event])
    after
      0 -> events
    end
  end
end
