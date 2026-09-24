defmodule Imp.RunAdmissionTest do
  # How many runs may be admitted at once is the host's setting when it names a
  # pool: `admission: {pool, limit}`. A full pool answers `{:error, :busy}` at
  # once, so the host keeps its own queue. Runs started without a pool share
  # the machine-wide `:async_max_workers` bound and wait for a slot there.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  defmodule Wait do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_program, %{owner: owner}) do
      send(owner, {:running, self()})

      receive do
        :finish -> {:ok, Imp.Prediction.new(%{answer: "done"})}
      end
    end
  end

  defmodule Stream do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_program, %{owner: owner}) do
      items = Imp.Tasks.async_stream([1, 2, 3], &(&1 * 2), ordered: true) |> Enum.to_list()
      send(owner, {:streamed, items})
      {:ok, Imp.Prediction.new(%{answer: "done"})}
    end
  end

  setup do
    Application.ensure_all_started(:imp)
    Imp.Settings.reset()
    on_exit(fn -> Imp.Settings.reset() end)
    :ok
  end

  defp start(pool, limit) do
    Imp.Run.start(%Wait{}, %{owner: self()}, admission: {pool, limit})
  end

  defp running do
    assert_receive {:running, pid}, 2_000
    pid
  end

  test "a named pool admits up to its limit and then answers busy at once" do
    pool = {:resident, make_ref()}

    assert {:ok, first} = start(pool, 2)
    assert {:ok, _second} = start(pool, 2)
    running()
    running()

    assert {:error, :busy} = start(pool, 2)

    send(first.task.pid, :finish)
    assert {:ok, _prediction} = Task.await(first.task)

    assert {:ok, _third} = start(pool, 2)
    running()
  end

  # On a build that admits every run to the machine-wide pool, the second start
  # here waits for a slot that never frees, and the test times out.
  @tag timeout: 5_000
  test "a named pool is not capped by the machine-wide bound" do
    Imp.configure(async_max_workers: 1)
    pool = {:resident, make_ref()}

    for _ <- 1..4, do: assert({:ok, _run} = start(pool, 4))
    for _ <- 1..4, do: running()
  end

  test "a stream a pooled run enumerates runs on the run's own place" do
    Imp.configure(async_max_workers: 1)
    parent = self()

    blocker =
      Imp.Tasks.async_nolink(fn ->
        send(parent, :machine_pool_full)
        receive(do: (:release -> :ok))
      end)

    assert_receive :machine_pool_full

    assert {:ok, _run} =
             Imp.Run.start(%Stream{}, %{owner: self()}, admission: {{:resident, make_ref()}, 1})

    assert_receive {:streamed, [ok: 2, ok: 4, ok: 6]}, 2_000
    send(blocker.pid, :release)
  end

  test "pools are independent of each other" do
    full = {:resident, make_ref()}
    other = {:resident, make_ref()}

    assert {:ok, _run} = start(full, 1)
    running()
    assert {:error, :busy} = start(full, 1)

    assert {:ok, _run} = start(other, 1)
    running()
  end

  test "a run that is cancelled or crashes gives its place back" do
    pool = {:resident, make_ref()}

    assert {:ok, run} = start(pool, 1)
    running()
    Imp.Run.cancel(run)
    assert {:ok, _run} = eventually_start(pool, 1)
    task = running()

    Process.exit(task, :kill)
    assert {:ok, _run} = eventually_start(pool, 1)
    running()
  end

  test "a busy start leaves no run behind" do
    pool = {:resident, make_ref()}
    assert {:ok, _run} = start(pool, 1)
    running()

    before = run_controls()
    assert {:error, :busy} = start(pool, 1)
    assert run_controls() == before
    refute_receive {:running, _pid}, 100
  end

  test "without a pool, runs past the machine-wide bound wait for a slot" do
    Imp.configure(async_max_workers: 1)
    owner = self()

    assert {:ok, first} = Imp.Run.start(%Wait{}, %{owner: owner})
    first_task = running()

    waiting = Task.async(fn -> Imp.Run.start(%Wait{}, %{owner: owner}) end)
    refute Task.yield(waiting, 200)

    send(first_task, :finish)
    assert {:ok, _prediction} = Task.await(first.task)
    assert {:ok, _second} = Task.await(waiting)
  end

  test "an admission that is not a pool and a positive limit is refused by name" do
    assert_raise ArgumentError, ~r/:admission/, fn ->
      Imp.Run.start(%Wait{}, %{owner: self()}, admission: {:pool, 0})
    end

    assert_raise ArgumentError, ~r/:admission/, fn ->
      Imp.Run.start(%Wait{}, %{owner: self()}, admission: 4)
    end
  end

  defp run_controls do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") == {Imp.Run.Control, :init, 1}

        nil ->
          false
      end
    end)
  end

  # A place is given back when the pool sees the run's process end, which may be
  # just after the caller does.
  defp eventually_start(pool, limit, attempts \\ 50) do
    case start(pool, limit) do
      {:error, :busy} when attempts > 0 ->
        Process.sleep(10)
        eventually_start(pool, limit, attempts - 1)

      result ->
        result
    end
  end
end
