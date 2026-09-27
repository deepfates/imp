defmodule EffectLifecycleTest do
  # Not async: these tests read the machine-wide task pool, which other tests
  # running at the same time would also be using.
  use ExUnit.Case, async: false

  alias Imp.Predict.RLM

  test "an RLM effect ends and gives back its pool place when a caller outside a run is killed" do
    parent = self()

    tool =
      Imp.tool(:hang, "Never returns.", fn _arguments ->
        send(parent, {:tool_started, self()})
        Process.sleep(:infinity)
      end)

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: "x = hang(%{})"} end)
    rlm = RLM.new("question -> answer", lm: lm, tools: [tool], max_iterations: 2)
    assert %{active: 0} = Imp.Tasks.admission_status()

    caller = spawn(fn -> RLM.call(rlm, %{question: "q"}) end)
    assert_receive {:tool_started, effect_pid}, 1_000
    assert %{active: 1} = Imp.Tasks.admission_status()

    effect_monitor = Process.monitor(effect_pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect_pid, _reason}, 1_000
    assert %{active: 0} = Imp.Tasks.admission_status()
  end

  test "an RLM call leaves no admission lease of its effects in its caller" do
    lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: ~s[submit(%{answer: "x"})]} end)

    rlm = RLM.new("question -> answer", lm: lm, max_iterations: 2)

    assert {:ok, _prediction} = RLM.call(rlm, %{question: "q"})

    # Parallel work the caller starts next runs as many calls at once as it
    # asks for, rather than one at a time on a lease an effect held. The
    # gate lets the calls finish once three are waiting together, or after a
    # second, and reports how many it saw at once.
    parent = self()
    gate = spawn_link(fn -> gate(parent, [], 3) end)

    waiting =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(gate, {:waiting, self()})
          receive do: (:go -> %{answer: "ok"})
        end
      )

    program = Imp.Predict.new("question -> answer", lm: waiting)
    inputs = for n <- 1..3, do: %{question: "q#{n}"}

    assert [ok: _, ok: _, ok: _] =
             Imp.Predict.Parallel.map(program, inputs, num_threads: 3)

    assert_received {:at_once, 3}
  end

  # An Avatar tool takes no place in the task pool, so an Avatar inside work
  # that holds the only place still runs its tools.
  test "Avatar in parallel inside an admitted task returns with a pool of one" do
    avatar = Imp.avatar("question -> answer", [lookup()], lm: tool_lm("lookup"), max_iters: 1)

    task =
      Imp.context([async_max_workers: 1], fn ->
        Imp.Tasks.async_nolink(fn ->
          Imp.Predict.Parallel.map(avatar, [%{question: "a"}, %{question: "b"}], num_threads: 2)
        end)
      end)

    assert {:ok, [ok: first, ok: second]} = Task.yield(task, 3_000) || Task.shutdown(task)
    assert [%{tool_output: "found"}] = Imp.get(first, :actions)
    assert [%{tool_output: "found"}] = Imp.get(second, :actions)
  end

  test "an Avatar whose tool calls another Avatar returns inside a run with a pool of one" do
    inner = Imp.avatar("question -> answer", [lookup()], lm: tool_lm("lookup"), max_iters: 1)

    outer_tool =
      Imp.tool(:inner, "Asks the inner agent.", fn _arguments ->
        {:ok, prediction} = Imp.call(inner, %{question: "x"})
        Imp.get(prediction, :answer)
      end)

    outer =
      Imp.avatar("question -> answer", [outer_tool],
        lm: tool_lm("inner"),
        max_iters: 1,
        tool_timeout_ms: 2_000
      )

    assert {:ok, run} =
             Imp.context([async_max_workers: 1], fn -> Imp.start_run(outer, %{question: "q"}) end)

    assert {:ok, {:ok, prediction}} = Task.yield(run.task, 3_000)
    assert [%{tool_output: "done"}] = Imp.get(prediction, :actions)
    Imp.Run.stop(run)
  end

  test "parallel work inside an Avatar tool runs on the run's place with a pool of one" do
    inner = Imp.Predict.new("question -> answer", lm: Imp.LM.Static.new(answer: "i"))

    tool =
      Imp.tool(:parallel, "Runs two calls.", fn _arguments ->
        inner
        |> Imp.Predict.Parallel.map([%{question: "a"}, %{question: "b"}], num_threads: 2)
        |> Enum.map(&elem(&1, 0))
      end)

    avatar =
      Imp.avatar("question -> answer", [tool],
        lm: tool_lm("parallel"),
        max_iters: 1,
        tool_timeout_ms: 1_500
      )

    assert {:ok, run} =
             Imp.context([async_max_workers: 1], fn -> Imp.start_run(avatar, %{question: "q"}) end)

    assert {:ok, {:ok, prediction}} = Task.yield(run.task, 3_000)
    assert [%{tool_output: [:ok, :ok]}] = Imp.get(prediction, :actions)
    Imp.Run.stop(run)
  end

  defp lookup, do: Imp.tool(:lookup, "Answers.", fn _arguments -> "found" end)

  defp tool_lm(name) do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        if Enum.map_join(messages, "\n", & &1.content) =~ "Do not request another tool.",
          do: %{answer: "done"},
          else: %{action: %{tool_name: name, tool_input_query: %{}}}
      end
    )
  end

  defp gate(parent, waiting, 0) do
    send(parent, {:at_once, length(waiting)})
    Enum.each(waiting, &send(&1, :go))
    gate_release()
  end

  defp gate(parent, waiting, remaining) do
    receive do
      {:waiting, pid} -> gate(parent, [pid | waiting], remaining - 1)
    after
      1_000 ->
        send(parent, {:at_once, length(waiting)})
        Enum.each(waiting, &send(&1, :go))
        gate_release()
    end
  end

  defp gate_release do
    receive do
      {:waiting, pid} ->
        send(pid, :go)
        gate_release()
    end
  end
end
