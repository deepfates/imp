defmodule Imp.DeadlinePropagationTest do
  use ExUnit.Case, async: true

  # A deadline bound with `Imp.Deadline.with_deadline/2` belongs to the calling
  # process. These tests check that the work Imp starts on the caller's behalf
  # in other processes -- its tasks, parallel maps, best-of-n attempts and
  # runs -- reads the same bound, so nested work cannot outlive it.

  @reached 5_000

  defp reporting_lm do
    test = self()

    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        send(test, {:model_deadline, self(), Imp.Deadline.current()})
        %{answer: "ok"}
      end
    )
  end

  defp deadlines_seen(count) do
    for _ <- 1..count do
      assert_receive {:model_deadline, pid, deadline}, @reached
      {pid, deadline}
    end
  end

  test "every Imp.Tasks entry point carries the caller's deadline" do
    Imp.Deadline.with_deadline(60_000, fn ->
      bound = Imp.Deadline.current()
      assert is_integer(bound)

      assert bound == Task.await(Imp.Tasks.async(&Imp.Deadline.current/0))
      assert bound == Task.await(Imp.Tasks.async_nolink(&Imp.Deadline.current/0))

      assert [{:ok, ^bound}, {:ok, ^bound}] =
               Enum.to_list(Imp.Tasks.async_stream([1, 2], fn _ -> Imp.Deadline.current() end))

      assert {:ok, task} =
               Imp.Tasks.async_nolink_in_pool(&Imp.Deadline.current/0, make_ref(), 1)

      assert bound == Task.await(task)
    end)
  end

  test "a task of a caller with no deadline has none" do
    assert :infinity == Task.await(Imp.Tasks.async(&Imp.Deadline.current/0))
  end

  test "a worker's own deadline can shorten the inherited one but not extend it" do
    Imp.Deadline.with_deadline(60_000, fn ->
      bound = Imp.Deadline.current()

      {shorter, longer} =
        Task.await(
          Imp.Tasks.async(fn ->
            {Imp.Deadline.with_deadline(1_000, &Imp.Deadline.current/0),
             Imp.Deadline.with_deadline(600_000, &Imp.Deadline.current/0)}
          end)
        )

      assert shorter < bound
      assert longer == bound
    end)
  end

  test "Imp.parallel model calls see the caller's deadline" do
    program = Imp.predict("q -> answer", lm: reporting_lm())

    bound =
      Imp.Deadline.with_deadline(60_000, fn ->
        assert [{:ok, _}, {:ok, _}, {:ok, _}] =
                 Imp.parallel(program, [%{q: "a"}, %{q: "b"}, %{q: "c"}])

        Imp.Deadline.current()
      end)

    seen = deadlines_seen(3)
    assert Enum.any?(seen, fn {pid, _} -> pid != self() end)
    assert Enum.all?(seen, fn {_pid, deadline} -> deadline == bound end)
  end

  test "best_of_n attempts see the caller's deadline" do
    program = Imp.predict("q -> answer", lm: reporting_lm())
    best = Imp.best_of_n(program, fn _inputs, _prediction -> 0.0 end, n: 2)

    bound =
      Imp.Deadline.with_deadline(60_000, fn ->
        Imp.call(best, %{q: "a"})
        Imp.Deadline.current()
      end)

    seen = deadlines_seen(2)
    assert Enum.all?(seen, fn {_pid, deadline} -> deadline == bound end)
  end

  test "a run inherits the caller's deadline" do
    program = Imp.predict("q -> answer", lm: reporting_lm())

    bound =
      Imp.Deadline.with_deadline(60_000, fn ->
        {:ok, run} = Imp.start_run(program, %{q: "a"})
        assert {:ok, _} = Task.await(run.task, @reached)
        Imp.Deadline.current()
      end)

    assert [{_pid, ^bound}] = deadlines_seen(1)
  end

  test "a run's deadline option bounds its model calls and is capped by the caller's" do
    program = Imp.predict("q -> answer", lm: reporting_lm())
    before = System.monotonic_time(:millisecond)

    {:ok, run} = Imp.start_run(program, %{q: "a"}, deadline: 30_000)
    assert {:ok, _} = Task.await(run.task, @reached)
    assert [{_pid, deadline}] = deadlines_seen(1)

    assert deadline >= before + 30_000 and
             deadline <= System.monotonic_time(:millisecond) + 30_000

    {caller, _} =
      Imp.Deadline.with_deadline(10_000, fn ->
        {:ok, run} = Imp.start_run(program, %{q: "a"}, deadline: 600_000)
        {Imp.Deadline.current(), Task.await(run.task, @reached)}
      end)

    assert [{_pid, ^caller}] = deadlines_seen(1)
  end

  test "start_run(deadline: 200) caps a model request that would otherwise wait" do
    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        Process.sleep(5_000)
        {200, %{}}
      end)

    lm =
      Imp.req_llm(
        %{provider: :openai, id: "slow", model: "slow", base_url: base_url <> "/v1"},
        api_key: "local-test-key",
        cache: false
      )

    program = Imp.predict("q -> answer", lm: lm)

    {microseconds, result} =
      :timer.tc(fn ->
        {:ok, run} = Imp.start_run(program, %{q: "a"}, deadline: 200)
        Task.await(run.task, 10_000)
      end)

    assert {:error, _reason} = result
    assert div(microseconds, 1_000) < 2_000
  end

  test "an invalid deadline option raises" do
    program = Imp.predict("q -> answer", lm: reporting_lm())

    assert_raise ArgumentError, ~r/deadline/, fn ->
      Imp.start_run(program, %{q: "a"}, deadline: -1)
    end
  end
end
