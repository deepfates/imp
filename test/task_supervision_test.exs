defmodule TaskSupervisionTest do
  use ExUnit.Case, async: false

  test "DSEx starts a supervised task boundary" do
    assert DSEx.Tasks.supervised?()
    assert is_pid(Process.whereis(DSEx.Tasks.supervisor()))
    assert is_pid(Process.whereis(DSEx.Tasks.unlinked_supervisor()))
  end

  test "DSEx.Tasks.async runs under DSEx.TaskSupervisor when the app is started" do
    parent = self()

    task =
      DSEx.Tasks.async(fn ->
        send(parent, {:task_started, self()})

        receive do
          :release -> :ok
        after
          1_000 -> :timeout
        end
      end)

    assert_receive {:task_started, pid}
    assert pid == task.pid
    assert pid in Task.Supervisor.children(DSEx.Tasks.supervisor())

    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "DSEx.Tasks.async starts the OTP application before supervised work" do
    :ok = Application.stop(:dsex)
    refute Process.whereis(DSEx.TaskSupervisor)

    task = DSEx.Tasks.async(fn -> Process.whereis(DSEx.TaskSupervisor) end)

    assert Task.await(task) == Process.whereis(DSEx.TaskSupervisor)
    assert Process.whereis(DSEx.Settings)
    assert Process.whereis(DSEx.Cache)
    assert Process.whereis(DSEx.UnlinkedTaskSupervisor)
  end

  test "DSEx.Tasks.async_nolink runs under the unlinked task supervisor" do
    parent = self()

    task =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, {:task_started, self()})

        receive do
          :release -> :ok
        after
          1_000 -> :timeout
        end
      end)

    assert_receive {:task_started, pid}
    assert pid == task.pid
    assert pid in Task.Supervisor.children(DSEx.Tasks.unlinked_supervisor())
    refute pid in Task.Supervisor.children(DSEx.Tasks.supervisor())

    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "parallel prediction uses the DSEx task boundary" do
    program =
      DSEx.predict("question -> answer",
        lm: %{
          module: DSEx.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: inspect(self())} end]
        }
      )

    results =
      DSEx.Predict.Parallel.map(program, [%{question: "a"}, %{question: "b"}], max_concurrency: 2)

    assert [{:ok, first}, {:ok, second}] = results
    assert DSEx.get(first, :answer) != DSEx.get(second, :answer)
  end
end
