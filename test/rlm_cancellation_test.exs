defmodule RLMCancellationTest do
  use ExUnit.Case, async: true

  alias DSEx.Predict.RLM
  alias DSEx.Predict.RLM.Budget

  test "cancellation terminates an active LM effect when no deadline is configured" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, {:effect_started, self()})
          Process.sleep(:infinity)
        end
      ]
    }

    rlm = RLM.new("question -> answer", lm: lm)
    call_task = Task.async(fn -> RLM.call(rlm, %{question: "cancel me"}) end)

    on_exit(fn ->
      if Process.alive?(call_task.pid), do: Task.shutdown(call_task, :brutal_kill)
    end)

    assert_receive {:effect_started, effect_pid}, 1_000
    effect_monitor = Process.monitor(effect_pid)
    budget = linked_budget(call_task.pid)

    assert :ok = Budget.cancel(budget, :caller_stopped)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect_pid, :killed}, 1_000

    assert {:error, {:rlm_effect_exit, :killed}} = Task.await(call_task, 1_000)
  end

  defp linked_budget(call_pid) do
    {:links, links} = Process.info(call_pid, :links)

    Enum.find(links, fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} ->
          Keyword.get(dictionary, :"$initial_call") == {Budget, :init, 1}

        nil ->
          false
      end
    end) || flunk("RLM call did not start a linked budget")
  end
end
