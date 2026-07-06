defmodule TaskSupervisionTest do
  use ExUnit.Case, async: false

  test "DSEx starts a supervised task boundary" do
    assert DSEx.Tasks.supervised?()
    assert is_pid(Process.whereis(DSEx.Tasks.supervisor()))
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

  test "parallel prediction uses the DSEx task boundary" do
    program =
      DSEx.predict("question -> answer",
        lm: %{
          module: DSEx.LM.Fake,
          opts: [handler: fn _messages, _opts -> %{answer: inspect(self())} end]
        }
      )

    results =
      DSEx.Predict.Parallel.map(program, [%{question: "a"}, %{question: "b"}], max_concurrency: 2)

    assert [{:ok, first}, {:ok, second}] = results
    assert DSEx.get(first, :answer) != DSEx.get(second, :answer)
  end
end
