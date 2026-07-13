defmodule TaskSupervisionTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    Application.ensure_all_started(:dsex)
    DSEx.Settings.reset()

    on_exit(fn ->
      Application.ensure_all_started(:dsex)
      DSEx.Settings.reset()
    end)

    :ok
  end

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

  test "core admission rejects excess async and generate_async work without queueing" do
    DSEx.configure(async_max_workers: 1)
    parent = self()

    blocker =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, {:blocked, self()})
        receive(do: (:release -> :released))
      end)

    assert_receive {:blocked, blocker_pid}
    assert DSEx.Tasks.admission_status() == %{active: 1, queued: 0}

    assert_raise DSEx.Tasks.OverloadedError, ~r/1\/1 workers active/, fn ->
      DSEx.Tasks.async(fn -> :never end)
    end

    assert_raise DSEx.Tasks.OverloadedError, fn ->
      DSEx.Tasks.async_nolink(fn -> :never end)
    end

    lm = %DSEx.Clients.ReqLLM{model: "test:model"}

    assert_raise DSEx.Tasks.OverloadedError, fn ->
      DSEx.Clients.ReqLLM.generate_async(lm, [%{role: :user, content: "never"}])
    end

    assert DSEx.Tasks.admission_status() == %{active: 1, queued: 0}
    send(blocker_pid, :release)
    assert Task.await(blocker) == :released
    assert DSEx.Tasks.admission_status() == %{active: 0, queued: 0}
    assert DSEx.Tasks.async_nolink(fn -> :reused end) |> Task.await() == :reused
  end

  test "crashes and cancellation release async admission" do
    DSEx.configure(async_max_workers: 1)

    crashing = DSEx.Tasks.async_nolink(fn -> raise "expected worker crash" end)
    assert catch_exit(Task.await(crashing))
    assert wait_for_active(0)

    parent = self()

    killed =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, :killable_started)
        Process.sleep(:infinity)
      end)

    assert_receive :killable_started
    Process.exit(killed.pid, :kill)
    assert catch_exit(Task.await(killed))
    assert wait_for_active(0)

    cancellable =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, :cancellable_started)
        Process.sleep(:infinity)
      end)

    assert_receive :cancellable_started
    assert DSEx.Tasks.cancel(cancellable, 1_000) == nil
    assert wait_for_active(0)
    assert DSEx.Tasks.async_nolink(fn -> :after_cancel end) |> Task.await() == :after_cancel
  end

  test "async_stream caps its own fan-out at the effective core limit" do
    DSEx.configure(async_max_workers: 2)
    parent = self()

    stream =
      DSEx.Tasks.async_stream(
        1..3,
        fn item ->
          send(parent, {:stream_started, item, self()})
          receive(do: (:release -> item))
        end,
        max_concurrency: 20,
        ordered: true
      )

    runner = Task.async(fn -> Enum.to_list(stream) end)
    assert_receive {:stream_started, first, first_pid}
    assert_receive {:stream_started, second, second_pid}
    refute_receive {:stream_started, _, _}
    assert MapSet.new([first, second]) == MapSet.new([1, 2])
    assert DSEx.Tasks.admission_status() == %{active: 2, queued: 0}

    send(first_pid, :release)
    assert_receive {:stream_started, 3, third_pid}
    send(second_pid, :release)
    send(third_pid, :release)

    assert Task.await(runner) == [ok: 1, ok: 2, ok: 3]
    assert DSEx.Tasks.admission_status() == %{active: 0, queued: 0}
  end

  test "async_stream reports external saturation explicitly" do
    DSEx.configure(async_max_workers: 1)
    parent = self()

    blocker =
      DSEx.Tasks.async_nolink(fn ->
        send(parent, {:stream_blocker, self()})
        receive(do: (:release -> :ok))
      end)

    assert_receive {:stream_blocker, blocker_pid}

    assert [{:exit, {%DSEx.Tasks.OverloadedError{}, _stack}}] =
             DSEx.Tasks.async_stream([:item], & &1) |> Enum.to_list()

    send(blocker_pid, :release)
    assert Task.await(blocker) == :ok
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

  defp wait_for_active(expected, attempts \\ 100)

  defp wait_for_active(expected, attempts) when attempts > 0 do
    case DSEx.Tasks.admission_status() do
      %{active: ^expected} ->
        true

      _status ->
        Process.sleep(5)
        wait_for_active(expected, attempts - 1)
    end
  end

  defp wait_for_active(_expected, 0), do: false
end
