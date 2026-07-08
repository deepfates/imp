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

  test "DSEx.Tasks reports invalid task boundaries clearly" do
    assert_raise ArgumentError, ~r/DSEx.Tasks.async\/1 expects a zero-arity function/, fn ->
      DSEx.Tasks.async(fn value -> value end)
    end

    assert_raise ArgumentError,
                 ~r/DSEx.Tasks.async_nolink\/1 expects a zero-arity function/,
                 fn ->
                   DSEx.Tasks.async_nolink(:not_a_function)
                 end

    assert_raise ArgumentError, ~r/DSEx.Tasks.async_stream\/3 expects enumerable input/, fn ->
      DSEx.Tasks.async_stream(:not_enumerable, fn value -> value end) |> Enum.to_list()
    end

    assert_raise ArgumentError, ~r/DSEx.Tasks.async_stream\/3 expects an arity-1 function/, fn ->
      DSEx.Tasks.async_stream([1], fn -> :ok end) |> Enum.to_list()
    end

    assert_raise ArgumentError, ~r/DSEx.Tasks.async_stream\/3: expected keyword options/, fn ->
      DSEx.Tasks.async_stream([1], fn value -> value end, %{ordered: true}) |> Enum.to_list()
    end

    assert_raise ArgumentError,
                 ~r/DSEx.Tasks.async_stream\/3.*:ordered.*expected.*boolean/s,
                 fn ->
                   DSEx.Tasks.async_stream([1], fn value -> value end, ordered: :sometimes)
                   |> Enum.to_list()
                 end
  end

  test "DSEx.Tasks.async_stream preserves context and accepts Task options" do
    DSEx.configure(task_marker: :outside)

    results =
      DSEx.context([task_marker: :inside], fn ->
        [1, 2]
        |> DSEx.Tasks.async_stream(
          fn value -> {value, DSEx.Settings.fetch!(:task_marker)} end,
          ordered: true,
          max_concurrency: 2,
          timeout: 1_000,
          on_timeout: :kill_task,
          zip_input_on_exit: true
        )
        |> Enum.to_list()
      end)

    assert results == [ok: {1, :inside}, ok: {2, :inside}]
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
