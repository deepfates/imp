defmodule Imp.RunEventSinkFailureOnceTest do
  # A stop that lands just after the sink failed on an event, before delivery
  # has moved past it, must not report that event twice: a host that writes a
  # record per report would write two. The test ends the run's control the way
  # `cancel_with_events/3` and the owner's death do, without waiting for the
  # sink; `stop/1` waits for it first, which almost always closes the window
  # but not by construction.
  #
  # The window is a few reductions wide. To land in it, the test runs on one
  # scheduler, lowers the sink process's priority so the stop runs
  # before it resumes, and sweeps how many reductions the sink uses before it
  # fails so that, for some of them, it is scheduled out right after the
  # report. It is synchronous because it changes a VM-wide flag.
  use ExUnit.Case, async: false

  defmodule Wait do
    @behaviour Imp.Module
    defstruct [:signature]

    def call(_, %{owner: owner}) do
      send(owner, :waiting)
      Process.sleep(:infinity)
    end
  end

  test "a stop just after a sink failure reports the event once" do
    online = :erlang.system_flag(:schedulers_online, 1)
    on_exit(fn -> :erlang.system_flag(:schedulers_online, online) end)

    duplicated =
      for reductions <- 3_000..4_000, reduce: [] do
        duplicated ->
          {:ok, run} =
            Imp.Run.start(%Wait{}, %{owner: self()},
              event_sink: fn
                %{kind: :model_response} ->
                  Process.flag(:priority, :low)
                  :erlang.bump_reductions(reductions)
                  raise "store refused"

                _event ->
                  :ok
              end
            )

          assert_receive :waiting
          Imp.Run.with_context(run.control, fn -> Imp.Run.emit(:model_response, []) end)

          # Stop the run the moment the first report arrives.
          stop_on_report(run)
          reports = reports()
          Process.exit(run.task.pid, :kill)

          assert Enum.all?(reports, &(&1.sequence == 1))
          if length(reports) == 1, do: duplicated, else: [{reductions, reports} | duplicated]
      end

    assert duplicated == []
  end

  defp stop_on_report(run) do
    receive do
      {:imp_run_event_sink_failed, _run_id, failure} ->
        :ok = Imp.Run.Control.force_stop(run.control)
        send(self(), {:imp_run_event_sink_failed, run.id, failure})
    after
      0 -> stop_on_report(run)
    end
  end

  defp reports do
    receive do
      {:imp_run_event_sink_failed, _run_id, failure} -> [failure | reports()]
    after
      0 -> []
    end
  end
end
