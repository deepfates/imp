defmodule DSEx.Optimizer.GEPATimeoutTest do
  use ExUnit.Case, async: true

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
    assert %DSEx.Optimizer.GEPA{timeout: :infinity} =
             DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: :infinity)

    assert_raise ArgumentError, ~r/invalid value for :timeout option/, fn ->
      DSEx.Optimizer.GEPA.new(DSEx.Metrics.exact_match(:answer), timeout: -1)
    end
  end
end
