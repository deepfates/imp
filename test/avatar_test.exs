defmodule AvatarTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.Avatar.ActionOutput

  test "executes typed actions, finishes, and returns task outputs with history" do
    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) -> %{answer: "Paris"}
          prompt =~ "tool_output: \"Paris\"" -> finish_action()
          true -> %{action: %{tool_name: "lookup", tool_input_query: %{country: "France"}}}
        end
      end)

    lookup =
      Imp.tool(:lookup, "Look up a country capital", fn %{"country" => "France"} -> "Paris" end)

    avatar = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :finish

    assert [
             %ActionOutput{
               tool_name: :lookup,
               tool_input_query: %{country: "France"},
               tool_output: "Paris",
               error?: false
             }
           ] = Imp.get(prediction, :actions)
  end

  test "iteration exhaustion still produces a typed final prediction" do
    lm =
      actor_lm(fn prompt ->
        if finalizer?(prompt),
          do: %{answer: "best available"},
          else: %{action: %{tool_name: "lookup", tool_input_query: %{query: "x"}}}
      end)

    lookup = Imp.tool(:lookup, "lookup", fn _ -> "observed" end)
    avatar = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "q"})
    assert Imp.get(prediction, :answer) == "best available"
    assert Imp.get(prediction, :termination_reason) == :max_iters
    assert [%ActionOutput{tool_output: "observed"}] = Imp.get(prediction, :actions)
  end

  test "unknown, denied, and crashed tools become recoverable action observations" do
    parent = self()

    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) ->
            %{answer: "recovered"}

          prompt =~ "unknown_tool" or prompt =~ "tool_denied" or
              prompt =~ "tool_error" ->
            finish_action()

          prompt =~ "unknown case" ->
            %{action: %{tool_name: "missing", tool_input_query: %{query: "x"}}}

          prompt =~ "denied case" ->
            %{action: %{tool_name: "lookup", tool_input_query: %{query: "secret"}}}

          true ->
            %{action: %{tool_name: "crash", tool_input_query: %{query: "x"}}}
        end
      end)

    lookup = Imp.tool(:lookup, "lookup", fn _ -> send(parent, :lookup_called) end)
    crash = Imp.tool(:crash, "crash", fn _ -> raise "boom" end)

    avatar =
      Imp.avatar("question -> answer", [lookup, crash],
        lm: lm,
        max_iters: 2,
        tool_policy: [:crash]
      )

    assert {:ok, unknown} = Imp.call(avatar, %{question: "unknown case"})

    assert [%ActionOutput{tool_output: {:error, {:unknown_tool, "missing"}}, error?: true}] =
             Imp.get(unknown, :actions)

    assert {:ok, denied} = Imp.call(avatar, %{question: "denied case"})

    assert [
             %ActionOutput{
               tool_output: {:error, {:tool_denied, :lookup, :tool_policy}},
               error?: true
             }
           ] =
             Imp.get(denied, :actions)

    assert {:ok, crashed} = Imp.call(avatar, %{question: "crash case"})

    assert [
             %ActionOutput{
               tool_output: {:error, {:tool_error, :crash, %RuntimeError{message: "boom"}}},
               error?: true
             }
           ] =
             Imp.get(crashed, :actions)

    refute_received :lookup_called
  end

  test "returned errors and crashing policies become recoverable action observations" do
    lm =
      actor_lm(fn prompt ->
        cond do
          finalizer?(prompt) ->
            %{answer: "recovered"}

          prompt =~ "tool_policy_error" or prompt =~ "not_found" ->
            finish_action()

          prompt =~ "policy case" ->
            %{action: %{tool_name: "lookup", tool_input_query: %{mode: "policy"}}}

          true ->
            %{action: %{tool_name: "lookup", tool_input_query: %{mode: "returned_error"}}}
        end
      end)

    lookup = Imp.tool(:lookup, "lookup", fn _ -> {:error, :not_found} end)
    exploding_policy = fn _name, _arguments -> raise "policy exploded" end

    returned_error = Imp.avatar("question -> answer", [lookup], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(returned_error, %{question: "returned error case"})

    assert [%ActionOutput{tool_output: {:error, :not_found}, error?: true}] =
             Imp.get(prediction, :actions)

    policy_error =
      Imp.avatar("question -> answer", [lookup],
        lm: lm,
        max_iters: 2,
        tool_policy: exploding_policy
      )

    assert {:ok, prediction} = Imp.call(policy_error, %{question: "policy case"})

    assert [
             %ActionOutput{
               tool_output:
                 {:error,
                  {:tool_policy_error, :lookup, %RuntimeError{message: "policy exploded"}}},
               error?: true
             }
           ] = Imp.get(prediction, :actions)
  end

  test "a blocking tool is killed at its effect deadline and emits terminal trace evidence" do
    parent = self()

    lm =
      actor_lm(fn prompt ->
        if finalizer?(prompt) do
          send(parent, :timeout_finalizer_called)
          %{answer: "timed out safely"}
        else
          send(parent, :timeout_actor_called)
          %{action: %{tool_name: "blocking", tool_input_query: %{query: "slow"}}}
        end
      end)

    blocking =
      Imp.tool(:blocking, "blocking local callback", fn _arguments ->
        send(parent, {:blocking_tool_started, self()})
        Process.sleep(2_000)
        send(parent, :blocking_tool_late_side_effect)
        "too late"
      end)

    avatar =
      Imp.avatar("question -> answer", [blocking],
        lm: lm,
        max_iters: 5,
        tool_timeout_ms: 250
      )

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, prediction} = Imp.call(avatar, %{question: "q"})
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 1_000
    assert_received :timeout_actor_called
    assert_received :timeout_finalizer_called
    assert_received {:blocking_tool_started, tool_pid}
    refute Process.alive?(tool_pid)

    assert Imp.get(prediction, :answer) == "timed out safely"
    assert Imp.get(prediction, :termination_reason) == :tool_timeout

    assert [
             %ActionOutput{
               tool_name: :blocking,
               tool_input_query: %{query: "slow"},
               tool_output: {:error, {:tool_timeout, :blocking, 250}},
               error?: true,
               terminal_reason: :tool_timeout
             }
           ] = Imp.get(prediction, :actions)

    refute_receive :timeout_actor_called, 50
    refute_receive :blocking_tool_late_side_effect, 300
  end

  test "a timed-out tool reads as unknown, and a run records the call" do
    lm = hanging_tool_lm()

    avatar =
      Imp.avatar("question -> answer", [hanging_tool(self())], lm: lm, tool_timeout_ms: 100)

    assert {:ok, run} = Imp.start_run(avatar, %{question: "q"})
    assert {:ok, prediction} = Task.await(run.task)
    assert [%ActionOutput{tool_output: timeout}] = Imp.get(prediction, :actions)
    assert {:error, {:tool_timeout, :hang, 100}} = timeout
    assert Imp.Tool.outcome(timeout) == :unknown

    events = Imp.Run.events(run)
    assert [call] = Enum.filter(events, &(&1.kind == :tool_call))
    assert [result] = Enum.filter(events, &(&1.kind == :tool_result))
    assert call.tool_call_id == result.tool_call_id
    assert result.metadata.outcome == :unknown
    Imp.Run.stop(run)
  end

  test "a tool sees the caller's settings, run context and deadline" do
    parent = self()

    tool =
      Imp.tool(:hang, "Reports what it sees.", fn _arguments ->
        send(
          parent,
          {:seen, Imp.Settings.fetch!(:avatar_marker), Imp.Run.context(), Imp.Deadline.current()}
        )

        "seen"
      end)

    avatar = Imp.avatar("question -> answer", [tool], lm: hanging_tool_lm(), max_iters: 1)

    Imp.context([avatar_marker: :from_caller], fn ->
      Imp.Deadline.with_deadline(60_000, fn ->
        assert {:ok, _prediction} = Imp.call(avatar, %{question: "q"})
      end)
    end)

    assert_received {:seen, :from_caller, nil, deadline}
    assert deadline != :infinity

    assert {:ok, run} =
             Imp.context([avatar_marker: :from_run_caller], fn ->
               Imp.start_run(avatar, %{question: "q"})
             end)

    assert {:ok, _prediction} = Task.await(run.task)
    assert_received {:seen, :from_run_caller, control, _deadline}
    assert is_pid(control)
    Imp.Run.stop(run)
  end

  test "a tool ends when its caller is killed" do
    parent = self()
    avatar = Imp.avatar("question -> answer", [hanging_tool(parent)], lm: hanging_tool_lm())
    caller = spawn(fn -> Imp.call(avatar, %{question: "q"}) end)

    assert_receive {:tool_started, tool_pid}, 1_000
    tool_monitor = Process.monitor(tool_pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^tool_monitor, :process, ^tool_pid, _reason}, 1_000
  end

  test "a tool ends when its run is cancelled" do
    parent = self()
    avatar = Imp.avatar("question -> answer", [hanging_tool(parent)], lm: hanging_tool_lm())
    assert {:ok, run} = Imp.start_run(avatar, %{question: "q"})

    assert_receive {:tool_started, tool_pid}, 1_000
    tool_monitor = Process.monitor(tool_pid)
    assert :ok = Imp.Run.cancel(run, :test_cancel, 1_000)
    assert_receive {:DOWN, ^tool_monitor, :process, ^tool_pid, _reason}, 1_000
  end

  test "a tool ends when its run's owner dies" do
    parent = self()
    avatar = Imp.avatar("question -> answer", [hanging_tool(parent)], lm: hanging_tool_lm())

    owner =
      spawn(fn ->
        {:ok, _run} = Imp.start_run(avatar, %{question: "q"})
        Process.sleep(:infinity)
      end)

    assert_receive {:tool_started, tool_pid}, 1_000
    tool_monitor = Process.monitor(tool_pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^tool_monitor, :process, ^tool_pid, _reason}, 1_000
  end

  test "a tool whose linked helper crashes is an observation, not the caller's crash" do
    tool =
      Imp.tool(:hang, "Starts a helper that crashes.", fn _arguments ->
        spawn_link(fn -> exit(:boom) end)
        Process.sleep(:infinity)
      end)

    avatar = Imp.avatar("question -> answer", [tool], lm: hanging_tool_lm(), max_iters: 1)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "q"})
    assert [%ActionOutput{tool_output: output, error?: true}] = Imp.get(prediction, :actions)
    assert {:error, {:tool_task_exit, :hang, :boom}} = output
    assert Imp.Tool.outcome(output) == :unknown
  end

  test "a caller that traps exits gets no exit message from a tool call" do
    tool = Imp.tool(:hang, "Answers.", fn _arguments -> "fine" end)
    avatar = Imp.avatar("question -> answer", [tool], lm: hanging_tool_lm(), max_iters: 1)
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      {:ok, _prediction} = Imp.call(avatar, %{question: "q"})
      Process.sleep(50)
      send(parent, {:mailbox, Process.info(self(), :messages)})
    end)

    assert_receive {:mailbox, {:messages, []}}, 2_000
  end

  test "validates reserved fields and malformed actions" do
    assert_raise ArgumentError, ~r/reserved fields.*avatar_history/, fn ->
      Imp.avatar("avatar_history -> answer", [])
    end

    lm = actor_lm(fn _prompt -> %{action: %{tool_name: nil, tool_input_query: %{}}} end)
    avatar = Imp.avatar("question -> answer", [], lm: lm)

    assert {:error, {:invalid_avatar_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.call(avatar, [:not_a_pair])

    assert {:error, %Imp.AdapterParseError{kind: :invalid_fields, message: message}} =
             Imp.call(avatar, %{question: "q"})

    assert message =~ "action.tool_name is required"
  end

  defp hanging_tool(parent) do
    Imp.tool(:hang, "Never returns.", fn _arguments ->
      send(parent, {:tool_started, self()})
      Process.sleep(:infinity)
    end)
  end

  defp hanging_tool_lm do
    actor_lm(fn prompt ->
      if finalizer?(prompt),
        do: %{answer: "done"},
        else: %{action: %{tool_name: "hang", tool_input_query: %{}}}
    end)
  end

  defp actor_lm(handler) do
    Imp.LM.Static.new(handler: fn messages, _opts -> handler.(prompt(messages)) end)
  end

  defp prompt(messages), do: Enum.map_join(messages, "\n", & &1.content)
  defp finalizer?(prompt), do: prompt =~ "Do not request another tool."
  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}
end
