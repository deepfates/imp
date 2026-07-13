defmodule DSEx.Optimizer.GEPATimeoutTest do
  use ExUnit.Case, async: false

  defmodule ErrorCallback do
    @behaviour DSEx.Optimizer.GEPA.Callback

    @impl true
    def on_error(event, owner), do: send(owner, {:gepa_error, event.exception})
  end

  defp example do
    DSEx.example(question: "q", answer: "ok") |> DSEx.with_inputs(:question)
  end

  test "threads the optimizer timeout into trajectory evaluation and reports it" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Process.sleep(20)
          %{answer: "ok"}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    {_compiled, report} =
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
        generations: 0,
        timeout: 1
      )
      |> DSEx.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

    assert report.metadata.timeout == 1
    assert [%{candidate_id: "baseline", diagnostics: ["{:task_exit, :timeout}"]}] = report.errors
  end

  test "accepts infinity and rejects invalid timeout values" do
    assert %DSEx.Optimizer.GEPA{timeout: :infinity, proposal_timeout: :infinity} =
             DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: :infinity)

    assert %DSEx.Optimizer.GEPA{timeout: 100, proposal_timeout: 5} =
             DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
               timeout: 100,
               proposal_timeout: 5
             )

    assert_raise ArgumentError, ~r/invalid value for :timeout option/, fn ->
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: -1)
    end

    assert_raise ArgumentError, ~r/invalid value for :proposal_timeout option/, fn ->
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), proposal_timeout: -1)
    end
  end

  test "hung reflection LM inherits proposal timeout, is cancelled, and consumes its call" do
    owner = self()
    baseline = MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor))

    program =
      DSEx.predict("question -> answer",
        lm: %{
          module: DSEx.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "wrong"} end]
        }
      )

    reflection_lm = fn _messages, opts ->
      send(owner, {:reflection_lm_started, self(), opts})
      Process.sleep(:infinity)
    end

    started_at = System.monotonic_time(:millisecond)

    {_compiled, report} =
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer),
        generations: 1,
        timeout: 20,
        reflection_lm: reflection_lm,
        max_reflection_calls: 1,
        callbacks: [{ErrorCallback, owner}]
      )
      |> DSEx.Optimizer.GEPA.compile_with_report(program, [example()], [example()])

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_receive {:reflection_lm_started, worker, []}
    assert_receive {:gepa_error, :timeout}
    assert elapsed < 1_000
    assert report.metadata.proposal_timeout == 20
    assert report.metadata.reflection_calls == 1
    assert report.metadata.max_reflection_calls == 1
    assert report.metadata.rejected_candidates == 1

    assert eventually(fn ->
             not Process.alive?(worker) and
               MapSet.new(Task.Supervisor.children(DSEx.UnlinkedTaskSupervisor)) == baseline
           end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
