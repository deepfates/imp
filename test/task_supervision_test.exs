defmodule TaskSupervisionTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  defmodule NeverReturns do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_program, %{owner: owner}) do
      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  setup do
    Application.ensure_all_started(:imp)
    Imp.Settings.reset()

    on_exit(fn ->
      Application.ensure_all_started(:imp)
      Imp.Settings.reset()
    end)

    :ok
  end

  test "Imp starts a supervised task boundary" do
    assert Imp.Tasks.supervised?()
    assert is_pid(Process.whereis(Imp.Tasks.supervisor()))
    assert is_pid(Process.whereis(Imp.Tasks.unlinked_supervisor()))
  end

  test "Imp.Tasks.async runs under Imp.TaskSupervisor when the app is started" do
    parent = self()

    task =
      Imp.Tasks.async(fn ->
        send(parent, {:task_started, self()})

        receive do
          :release -> :ok
        after
          1_000 -> :timeout
        end
      end)

    assert_receive {:task_started, pid}
    assert pid == task.pid
    assert pid in Task.Supervisor.children(Imp.Tasks.supervisor())

    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "Imp.Tasks.async starts the OTP application before supervised work" do
    :ok = Application.stop(:imp)
    refute Process.whereis(Imp.TaskSupervisor)

    task = Imp.Tasks.async(fn -> Process.whereis(Imp.TaskSupervisor) end)

    assert Task.await(task) == Process.whereis(Imp.TaskSupervisor)
    assert Process.whereis(Imp.Settings)
    assert Process.whereis(Imp.Cache)
    assert Process.whereis(Imp.UnlinkedTaskSupervisor)
  end

  test "Imp.Tasks.async_nolink runs under the unlinked task supervisor" do
    parent = self()

    task =
      Imp.Tasks.async_nolink(fn ->
        send(parent, {:task_started, self()})

        receive do
          :release -> :ok
        after
          1_000 -> :timeout
        end
      end)

    assert_receive {:task_started, pid}
    assert pid == task.pid
    assert pid in Task.Supervisor.children(Imp.Tasks.unlinked_supervisor())
    refute pid in Task.Supervisor.children(Imp.Tasks.supervisor())

    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "core admission applies backpressure to excess async work" do
    Imp.configure(async_max_workers: 1)
    parent = self()

    blocker =
      Imp.Tasks.async_nolink(fn ->
        send(parent, {:blocked, self()})
        receive(do: (:release -> :released))
      end)

    assert_receive {:blocked, blocker_pid}

    submitter =
      Task.async(fn ->
        Imp.Tasks.async_nolink(fn -> :after_backpressure end) |> Task.await()
      end)

    assert wait_for_status(%{active: 1, queued: 1})
    send(blocker_pid, :release)
    assert Task.await(blocker) == :released
    assert Task.await(submitter) == :after_backpressure
    assert wait_for_status(%{active: 0, queued: 0})
  end

  test "crashes and cancellation release async admission" do
    Imp.configure(async_max_workers: 1)

    crashing = Imp.Tasks.async_nolink(fn -> raise "expected worker crash" end)
    assert catch_exit(Task.await(crashing))
    assert wait_for_active(0)

    parent = self()

    killed =
      Imp.Tasks.async_nolink(fn ->
        send(parent, :killable_started)
        Process.sleep(:infinity)
      end)

    assert_receive :killable_started
    Process.exit(killed.pid, :kill)
    assert catch_exit(Task.await(killed))
    assert wait_for_active(0)

    cancellable =
      Imp.Tasks.async_nolink(fn ->
        send(parent, :cancellable_started)
        Process.sleep(:infinity)
      end)

    assert_receive :cancellable_started
    assert Imp.Tasks.cancel(cancellable, 1_000) == nil
    assert wait_for_active(0)
    assert Imp.Tasks.async_nolink(fn -> :after_cancel end) |> Task.await() == :after_cancel
  end

  test "async_stream caps its own fan-out at the effective core limit" do
    Imp.configure(async_max_workers: 2)
    parent = self()

    stream =
      Imp.Tasks.async_stream(
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
    assert Imp.Tasks.admission_status() == %{active: 2, queued: 0}

    send(first_pid, :release)
    assert_receive {:stream_started, 3, third_pid}
    send(second_pid, :release)
    send(third_pid, :release)

    assert Task.await(runner) == [ok: 1, ok: 2, ok: 3]
    assert Imp.Tasks.admission_status() == %{active: 0, queued: 0}
  end

  test "async_stream waits for externally saturated capacity" do
    Imp.configure(async_max_workers: 1)
    parent = self()

    blocker =
      Imp.Tasks.async_nolink(fn ->
        send(parent, {:stream_blocker, self()})
        receive(do: (:release -> :ok))
      end)

    assert_receive {:stream_blocker, blocker_pid}

    runner = Task.async(fn -> Imp.Tasks.async_stream([:item], & &1) |> Enum.to_list() end)
    assert wait_for_status(%{active: 1, queued: 1})
    send(blocker_pid, :release)
    assert Task.await(blocker) == :ok
    assert Task.await(runner) == [ok: :item]
  end

  test "directly nested async_stream reuses one admission slot without deadlocking" do
    Imp.configure(async_max_workers: 1)

    runner =
      Task.async(fn ->
        Imp.Tasks.async_stream(
          [:outer],
          fn :outer ->
            before_inner = Imp.Tasks.admission_status()

            inner =
              Imp.Tasks.async_stream([1, 2], &{&1, Imp.Tasks.admission_status()}, ordered: true)
              |> Enum.to_list()

            {before_inner, inner}
          end,
          ordered: true
        )
        |> Enum.to_list()
      end)

    assert Task.await(runner, 1_000) == [
             ok:
               {%{active: 1, queued: 0},
                [ok: {1, %{active: 1, queued: 0}}, ok: {2, %{active: 1, queued: 0}}]}
           ]

    assert wait_for_status(%{active: 0, queued: 0})
  end

  test "async task may synchronously enumerate a nested stream with one worker" do
    Imp.configure(async_max_workers: 1)

    task =
      Imp.Tasks.async(fn ->
        Imp.Tasks.async_stream([1, 2], &{&1, Imp.Tasks.admission_status()}, ordered: true)
        |> Enum.to_list()
      end)

    assert Task.await(task, 1_000) == [
             ok: {1, %{active: 1, queued: 0}},
             ok: {2, %{active: 1, queued: 0}}
           ]

    assert wait_for_status(%{active: 0, queued: 0})
  end

  test "nested stream admission remains reentrant at deeper levels" do
    Imp.configure(async_max_workers: 1)

    task =
      Imp.Tasks.async(fn ->
        Imp.Tasks.async_stream([:middle], fn :middle ->
          Imp.Tasks.async_stream([:inner], &{&1, Imp.Tasks.admission_status()})
          |> Enum.to_list()
        end)
        |> Enum.to_list()
      end)

    assert Task.await(task, 1_000) == [
             ok: [ok: {:inner, %{active: 1, queued: 0}}]
           ]

    assert wait_for_status(%{active: 0, queued: 0})
  end

  test "a nested stream enumerated outside its lease uses ordinary admission" do
    Imp.configure(async_max_workers: 1)

    escaped =
      Imp.Tasks.async_stream(
        [:outer],
        fn :outer -> Imp.Tasks.async_stream([:inner], & &1) end,
        ordered: true
      )
      |> Enum.to_list()

    assert [ok: stream] = escaped
    assert Imp.Tasks.admission_status() == %{active: 0, queued: 0}
    assert Enum.to_list(stream) == [ok: :inner]
    assert wait_for_status(%{active: 0, queued: 0})
  end

  test "Imp.Tasks reports invalid task boundaries clearly" do
    assert_raise ArgumentError, ~r/Imp.Tasks.async\/1 expects a zero-arity function/, fn ->
      Imp.Tasks.async(fn value -> value end)
    end

    assert_raise ArgumentError,
                 ~r/Imp.Tasks.async_nolink\/1 expects a zero-arity function/,
                 fn ->
                   Imp.Tasks.async_nolink(:not_a_function)
                 end

    assert_raise ArgumentError, ~r/Imp.Tasks.async_stream\/3 expects enumerable input/, fn ->
      Imp.Tasks.async_stream(:not_enumerable, fn value -> value end) |> Enum.to_list()
    end

    assert_raise ArgumentError, ~r/Imp.Tasks.async_stream\/3 expects an arity-1 function/, fn ->
      Imp.Tasks.async_stream([1], fn -> :ok end) |> Enum.to_list()
    end

    assert_raise ArgumentError, ~r/Imp.Tasks.async_stream\/3: expected keyword options/, fn ->
      Imp.Tasks.async_stream([1], fn value -> value end, %{ordered: true}) |> Enum.to_list()
    end

    assert_raise ArgumentError,
                 ~r/Imp.Tasks.async_stream\/3.*:ordered.*expected.*boolean/s,
                 fn ->
                   Imp.Tasks.async_stream([1], fn value -> value end, ordered: :sometimes)
                   |> Enum.to_list()
                 end
  end

  test "Imp.Tasks.async_stream preserves context and accepts Task options" do
    results =
      Imp.context([task_marker: :inside], fn ->
        [1, 2]
        |> Imp.Tasks.async_stream(
          fn value -> {value, Imp.Settings.fetch!(:task_marker)} end,
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

  test "parallel prediction uses the Imp task boundary" do
    program =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: inspect(self())} end]
        }
      )

    results =
      Imp.Predict.Parallel.map(program, [%{question: "a"}, %{question: "b"}], max_concurrency: 2)

    assert [{:ok, first}, {:ok, second}] = results
    assert Imp.get(first, :answer) != Imp.get(second, :answer)
  end

  # Imp.Run.start/3 admits its task. cancel/3 ends the run and releases that
  # lease; stop/1 is documented only for a run that has already completed and
  # releases the control process alone, so stopping a still-running task leaves
  # its lease held for the life of the node.
  test "cancelling a run releases the admission lease it took" do
    assert wait_for_status(%{active: 0, queued: 0})

    {:ok, run} = Imp.Run.start(%NeverReturns{}, %{owner: self()})
    assert_receive :waiting
    assert wait_for_active(1)

    :ok = Imp.Run.cancel(run)

    assert wait_for_status(%{active: 0, queued: 0})
    refute Process.alive?(run.task.pid)
  end

  defp wait_for_active(expected, attempts \\ 100)

  defp wait_for_active(expected, attempts) when attempts > 0 do
    case Imp.Tasks.admission_status() do
      %{active: ^expected} ->
        true

      _status ->
        Process.sleep(5)
        wait_for_active(expected, attempts - 1)
    end
  end

  defp wait_for_active(_expected, 0), do: false

  defp wait_for_status(expected, attempts \\ 100)

  defp wait_for_status(expected, attempts) when attempts > 0 do
    if Imp.Tasks.admission_status() == expected do
      true
    else
      Process.sleep(5)
      wait_for_status(expected, attempts - 1)
    end
  end

  defp wait_for_status(_expected, 0), do: false
end
