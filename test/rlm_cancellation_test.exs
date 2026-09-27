defmodule RLMCancellationTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.RLM
  alias Imp.Predict.RLM.Budget

  test "cancellation terminates an active LM effect when no deadline is configured" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(parent, {:effect_started, self()})
          Process.sleep(:infinity)
        end
      )

    rlm = RLM.new("question -> answer", lm: lm)
    call_task = Task.async(fn -> RLM.call(rlm, %{question: "cancel me"}) end)

    on_exit(fn ->
      if Process.alive?(call_task.pid), do: Task.shutdown(call_task, :brutal_kill)
    end)

    assert_receive {:effect_started, effect_pid}, 1_000
    effect_monitor = Process.monitor(effect_pid)
    budget = call_budget(call_task.pid)

    assert :ok = Budget.cancel(budget, :caller_stopped)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect_pid, :killed}, 1_000

    assert {:error, {:rlm_effect_exit, :killed}} = Task.await(call_task, 1_000)
  end

  test "an effect stopped at the time limit leaves the call its budget" do
    tool = Imp.tool(:hang, "Never returns.", fn _arguments -> Process.sleep(:infinity) end)
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: "x = hang(%{})"} end)
    rlm = RLM.new("question -> answer", lm: lm, tools: [tool], max_time_ms: 200)

    assert {:error, {:rlm_max_time_ms, 200, [_step]}} = RLM.call(rlm, %{question: "q"})
  end

  defp call_budget(call_pid) do
    {:monitored_by, watchers} = Process.info(call_pid, :monitored_by)

    Enum.find(watchers, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") == {Budget, :init, 1}

        nil ->
          false
      end
    end) || flunk("RLM call did not start a budget")
  end
end
