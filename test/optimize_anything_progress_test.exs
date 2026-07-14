defmodule Imp.Optimize.Anything.ProgressTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything.Progress
  alias Imp.Optimizer.GEPA.Callback

  test "renders measured evaluation progress through the GEPA callback lifecycle" do
    {:ok, io} = StringIO.open("")
    callback = Progress.callback(io: io, total: 12)

    assert {:ok, [^callback]} = Callback.validate([callback])

    assert :ok = Callback.notify([callback], :on_optimization_start, %{})

    assert :ok =
             Callback.notify([callback], :on_budget_updated, %{metric_calls_used: 5})

    assert :ok =
             Callback.notify([callback], :on_optimization_end, %{total_metric_calls: 9})

    assert {_input, output} = StringIO.contents(io)

    assert output ==
             "GEPA Optimization: 0/12 evaluations\r" <>
               "GEPA Optimization: 5/12 evaluations\r" <>
               "GEPA Optimization: 9/12 evaluations\n"
  end

  test "supports an unknown total and validates display options" do
    {:ok, io} = StringIO.open("")
    callback = Progress.callback(io: io, label: "Search")

    Callback.notify([callback], :on_budget_updated, %{metric_calls_used: 3})
    assert {_input, "Search: 3 evaluations\r"} = StringIO.contents(io)

    assert_raise ArgumentError, ~r/total must be nil or non-negative/, fn ->
      Progress.callback(total: -1)
    end

    assert_raise ArgumentError, ~r/label must be a non-empty string/, fn ->
      Progress.callback(label: "")
    end
  end
end
