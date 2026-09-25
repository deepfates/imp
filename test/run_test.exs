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
    lookup = Imp.tool(:lookup, "lookup", fn %{"query" => query} -> "found " <> query end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "look it up",
            tool_calls: [
              %{id: "provider-call-1", name: "lookup", arguments: %{query: "beam"}},
              %{
                id: "provider-submit-1",
                name: "submit",
                arguments: %{answer: "BEAM", confidence: 1.0}
              }
            ]
          }
        end
      )

    program = Imp.react_v2("question -> answer, confidence: float", [lookup], lm: lm)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "runtime?"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, prediction} = Task.await(run.task)
    assert Imp.get(prediction, :answer) == "BEAM"
    :ok = Imp.Run.stop(run)

    events = receive_events([])
    assert Enum.map(events, & &1.sequence) == Enum.to_list(0..9)

    assert [
             %{kind: :run_started},
             %{kind: :tools_sent},
             %{kind: :model_request},
             %{kind: :model_response},
             %{kind: :reasoning, reasoning: "look it up"},
             %{kind: :tool_call, tool_call_id: "provider-call-1", tool_name: "lookup"},
             %{kind: :tool_result, tool_call_id: "provider-call-1", output: "found beam"},
             %{kind: :tool_call, tool_call_id: "provider-submit-1", tool_name: "submit"},
             %{kind: :tool_result, tool_call_id: "provider-submit-1"},
             %{kind: :run_finished}
           ] = events

    assert Enum.all?(events, &(&1.kind in Imp.Run.Event.kinds()))
  end

  test "start refuses an option it does not know before starting anything" do
    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _, _ -> %{answer: "x"} end)
      )

    # A misspelled :authorize would otherwise start a run whose tool calls
    # nobody is asked about, and a misspelled :admission would count it in the
    # machine-wide pool.
    for typo <- [[authorise: fn _ -> :allow end], [admision: {:agent, 1}]] do
      error = assert_raise ArgumentError, fn -> Imp.Run.start(program, %{question: "q"}, typo) end
      assert Exception.message(error) =~ "unknown options"
    end

    assert_raise ArgumentError, ~r/positive integer limit/, fn ->
      Imp.Run.start(program, %{question: "q"}, admission: {:agent, 0})
    end
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

  # The model call an RLM run has in flight is its budget's to end, and the
  # budget ends with the run's task. So the cancellations are called before
  # the task is ended, or the call is left running with nobody to end it.
  test "a run whose control ends cancels its RLM's in-flight model call" do
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
    on_exit(fn -> Process.exit(effect_pid, :kill) end)
    monitor = Process.monitor(effect_pid)

    Process.exit(run.control, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^effect_pid, :killed}, 2_000
  end

  test "a blocked event sink cannot delay cancellation or leak its delivery process" do
    owner = self()
    program = %BlockingProgram{signature: Imp.signature("question -> answer")}

    assert {:ok, run} =
             Imp.start_run(program, %{question: "wait"},
               event_sink: fn event ->
                 if event.kind == :run_started do
                   send(owner, {:sink_blocked, self()})
                   Process.sleep(:infinity)
                 end
               end
             )

    assert_receive {:sink_blocked, delivery}
    refute delivery == run.control

    delivery_monitor = Process.monitor(delivery)
    task_monitor = Process.monitor(run.task.pid)
    control_monitor = Process.monitor(run.control)

    cancel = Task.async(fn -> Imp.cancel_run(run, :probe_cancel, 100) end)
    assert :ok = Task.await(cancel, 500)

    assert_receive {:DOWN, ^task_monitor, :process, _pid, _reason}, 500
    assert_receive {:DOWN, ^control_monitor, :process, _pid, _reason}, 500
    assert_receive {:DOWN, ^delivery_monitor, :process, _pid, _reason}, 500
  end

  test "event barriers follow sink delivery order without occupying the control plane" do
    owner = self()
    program = %NestedProgram{signature: Imp.signature("question -> answer")}

    assert {:ok, run} =
             Imp.start_run(program, %{question: "ordered"},
               event_sink: fn event ->
                 if event.kind == :run_started do
                   send(owner, {:sink_waiting, self()})
                   receive do: (:release_sink -> :ok)
                 end

                 send(owner, {:delivered, event.sequence})
               end
             )

    assert_receive {:sink_waiting, delivery}
    assert {:ok, _prediction} = Task.await(run.task)
    assert :ok = Imp.Run.barrier(run, owner, :ordered)
    refute_receive {:imp_run_barrier, :ordered}, 20

    send(delivery, :release_sink)
    assert_receive {:imp_run_barrier, :ordered}, 500
    :ok = Imp.Run.stop(run)

    delivered = receive_delivered([])
    assert delivered == Enum.to_list(0..2)
  end

  test "run owner death cleans up a blocked observer and outer execution" do
    test_pid = self()

    owner =
      spawn(fn ->
        program = %BlockingProgram{signature: Imp.signature("question -> answer")}

        {:ok, run} =
          Imp.start_run(program, %{question: "wait"},
            event_sink: fn event ->
              if event.kind == :run_started do
                send(test_pid, {:owner_sink_blocked, self()})
                Process.sleep(:infinity)
              end
            end
          )

        send(test_pid, {:owner_blocked_run, run})
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_blocked_run, run}
    assert_receive {:owner_sink_blocked, delivery}

    task_monitor = Process.monitor(run.task.pid)
    control_monitor = Process.monitor(run.control)
    delivery_monitor = Process.monitor(delivery)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^task_monitor, :process, _pid, _reason}, 500
    assert_receive {:DOWN, ^control_monitor, :process, _pid, _reason}, 500
    assert_receive {:DOWN, ^delivery_monitor, :process, _pid, _reason}, 500
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

  test "authorization-aware runs fail closed for modules without execute/3" do
    program = %NestedProgram{signature: Imp.signature("question -> answer")}

    assert {:ok, run} =
             Imp.start_run(program, %{question: "no implicit fallback"},
               authorize: fn _request -> :allow end
             )

    assert {:error, {:execution_capability_unsupported, NestedProgram, :authorization}} =
             Task.await(run.task)

    :ok = Imp.Run.stop(run)
  end

  test "ReActV2 validates before authorization and turns denial into an observation" do
    owner = self()
    {:ok, responses} = Agent.start_link(fn -> :invalid end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(responses, fn
            :invalid ->
              {%{
                 tool_calls: [
                   %{id: "invalid-1", name: "lookup", arguments: %{}}
                 ]
               }, :denied}

            :denied ->
              {%{
                 tool_calls: [
                   %{id: "lookup-2", name: "lookup", arguments: %{query: "beam"}},
                   %{
                     id: "submit-2",
                     name: "submit",
                     arguments: %{answer: "denied safely", confidence: 1.0}
                   }
                 ]
               }, :done}
          end)
        end
      )

    lookup =
      Imp.tool(
        :lookup,
        "read external data",
        fn args ->
          send(owner, {:tool_executed, args})
          "found"
        end,
        schema: %{
          "type" => "object",
          "required" => ["query"],
          "properties" => %{"query" => %{"type" => "string"}}
        }
      )

    program =
      Imp.react_v2("question -> answer, confidence: float", [lookup], lm: lm, max_iters: 2)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "lookup"},
               authorize: fn request ->
                 send(owner, {:authorization_requested, request})
                 {:deny, :human_rejected}
               end
             )

    assert {:ok, prediction} = Task.await(run.task)
    :ok = Imp.Run.barrier(run, owner, :denied)
    assert_receive {:imp_run_barrier, :denied}
    :ok = Imp.Run.stop(run)

    assert_receive {:authorization_requested,
                    %Imp.Execution.Authorization{
                      tool_call_id: "lookup-2",
                      tool_name: :lookup,
                      arguments: %{"query" => "beam"}
                    }}

    refute_received {:authorization_requested,
                     %Imp.Execution.Authorization{tool_call_id: "invalid-1"}}

    refute_received {:tool_executed, _args}
    assert Imp.get(prediction, :answer) == "denied safely"

    [first | _] = prediction.metadata.history.messages

    assert Enum.any?(first.tool_call_results, fn result ->
             result.id == "invalid-1" and result.error
           end)
  end

  test "an authorization cancellation stops ReActV2 without executing the effect" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{id: "external-1", name: "external", arguments: %{value: "x"}}
            ]
          }
        end
      )

    tool = Imp.tool(:external, "external write", fn args -> send(owner, {:effect, args}) end)
    program = Imp.react_v2("question -> answer", [tool], lm: lm)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "write"},
               event_sink: fn event -> send(owner, {:run_event, event}) end,
               authorize: fn _request -> {:cancel, :operator_cancelled} end
             )

    assert {:error, {:execution_cancelled, :operator_cancelled}} = Task.await(run.task)
    :ok = Imp.Run.barrier(run, owner, :cancelled)
    assert_receive {:imp_run_barrier, :cancelled}
    :ok = Imp.Run.stop(run)

    refute_received {:effect, _args}
    events = receive_events([])
    assert Enum.any?(events, &(&1.kind == :tool_call and &1.tool_call_id == "external-1"))
    assert Enum.any?(events, &(&1.kind == :run_cancelled))
    refute Enum.any?(events, &(&1.kind == :tool_result and &1.tool_call_id == "external-1"))
  end

  test "cancelling a run stops a blocked authorization callback without a late decision" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{id: "external-blocked", name: "external", arguments: %{}}]}
        end
      )

    tool = Imp.tool(:external, "external write", fn _args -> send(owner, :effect_executed) end)
    program = Imp.react_v2("question -> answer", [tool], lm: lm)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "write"},
               authorize: fn _request ->
                 send(owner, {:authorization_callback_started, self()})
                 Process.sleep(:infinity)
                 send(owner, :late_authorization_decision)
                 :allow
               end,
               authorization_timeout: 5_000
             )

    assert_receive {:authorization_callback_started, callback}
    callback_monitor = Process.monitor(callback)

    assert :ok = Imp.cancel_run(run, :operator_cancelled)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _reason}
    refute Process.alive?(run.task.pid)
    refute_received :effect_executed
    refute_receive :late_authorization_decision, 20
  end

  test "run owner death stops a blocked authorization callback and outer execution" do
    test_pid = self()

    owner =
      spawn(fn ->
        lm =
          Imp.LM.Static.new(
            handler: fn _messages, _opts ->
              %{tool_calls: [%{id: "owner-down", name: "external", arguments: %{}}]}
            end
          )

        tool =
          Imp.tool(:external, "external write", fn _args -> send(test_pid, :effect_executed) end)

        program = Imp.react_v2("question -> answer", [tool], lm: lm)

        {:ok, run} =
          Imp.start_run(program, %{question: "write"},
            authorize: fn _request ->
              send(test_pid, {:owner_authorization_started, self()})
              Process.sleep(:infinity)
              send(test_pid, :late_authorization_decision)
              :allow
            end,
            authorization_timeout: 5_000
          )

        send(test_pid, {:owned_run, run})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned_run, run}
    assert_receive {:owner_authorization_started, callback}
    callback_monitor = Process.monitor(callback)
    run_monitor = Process.monitor(run.task.pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _reason}
    assert_receive {:DOWN, ^run_monitor, :process, _run_pid, _reason}
    refute_received :effect_executed
    refute_receive :late_authorization_decision, 20
  end

  test "RLM explicitly carries authorization into its budgeted tool effect" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{code: ~S|external(%{value: "x"})|}
        end
      )

    tool =
      Imp.tool(:external, "external RLM write", fn args -> send(owner, {:rlm_effect, args}) end)

    program = Imp.rlm("question -> answer", lm: lm, tools: [tool], max_iterations: 1)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "write"},
               authorize: fn request ->
                 send(owner, {:rlm_authorization, request})
                 {:cancel, :rlm_operator_cancelled}
               end
             )

    assert {:error, {:execution_cancelled, :rlm_operator_cancelled}} = Task.await(run.task)
    :ok = Imp.Run.stop(run)

    assert_receive {:rlm_authorization,
                    %Imp.Execution.Authorization{
                      tool_name: :external,
                      arguments: %{"value" => "x"}
                    }}

    refute_received {:rlm_effect, _args}
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
    control_monitor = Process.monitor(run.control)
    send(owner, :crash)

    assert_receive {:DOWN, ^task_monitor, :process, _pid, :killed}, 1_000
    assert_receive {:DOWN, ^control_monitor, :process, _pid, _reason}, 1_000
  end

  defp receive_events(events) do
    receive do
      {:run_event, event} -> receive_events(events ++ [event])
    after
      0 -> events
    end
  end

  defp receive_delivered(sequences) do
    receive do
      {:delivered, sequence} -> receive_delivered([sequence | sequences])
    after
      10 -> Enum.reverse(sequences)
    end
  end
end
