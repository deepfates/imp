defmodule Imp.ExecutionTest do
  use ExUnit.Case, async: true

  alias Imp.Execution.Authorization

  test "authorization callback failures, malformed decisions, and timeouts deny" do
    request = request()

    crashing =
      Imp.Execution.new(
        authorize: fn _ -> raise "decision service failed" end,
        authorization_timeout: 100
      )

    assert {:deny, {:authorization_callback_exit, _reason}} =
             Imp.Execution.authorize(crashing, request)

    fatally_exiting =
      Imp.Execution.new(
        authorize: fn _ -> Process.exit(self(), :kill) end,
        authorization_timeout: 100
      )

    assert {:deny, {:authorization_callback_exit, :killed}} =
             Imp.Execution.authorize(fatally_exiting, request)

    malformed = Imp.Execution.new(authorize: fn _ -> :yes end)

    assert {:deny, {:invalid_authorization_decision, :yes}} =
             Imp.Execution.authorize(malformed, request)

    timeout =
      Imp.Execution.new(
        authorize: fn _ -> Process.sleep(:infinity) end,
        authorization_timeout: 10
      )

    assert {:deny, :authorization_timeout} = Imp.Execution.authorize(timeout, request)
  end

  test "a vanished decision owner cannot authorize an effect" do
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}

    execution =
      Imp.Execution.new(
        authorize: fn _ -> :allow end,
        decision_owner: owner
      )

    assert {:deny, :authorization_owner_down} =
             Imp.Execution.authorize(execution, request())
  end

  test "decision owner death stops a blocked authorization callback without a late decision" do
    test_pid = self()
    owner = spawn(fn -> Process.sleep(:infinity) end)

    execution =
      Imp.Execution.new(
        authorize: fn _request ->
          send(test_pid, {:authorization_callback_started, self()})
          Process.sleep(:infinity)
          send(test_pid, :late_authorization_decision)
          :allow
        end,
        decision_owner: owner,
        authorization_timeout: 5_000
      )

    caller = Task.async(fn -> Imp.Execution.authorize(execution, request()) end)
    assert_receive {:authorization_callback_started, callback}
    callback_monitor = Process.monitor(callback)

    Process.exit(owner, :kill)

    assert {:deny, :authorization_owner_down} = Task.await(caller)
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _reason}
    refute_receive :late_authorization_decision, 20
  end

  test "authorization descriptions are bounded without changing decision arguments" do
    assert String.length(Imp.Execution.bounded_description(String.duplicate("x", 1_500))) == 1_000
    assert Imp.Execution.bounded_description(nil) == nil
  end

  defp request do
    %Authorization{
      run_id: "run-test",
      tool_call_id: "call-test",
      tool_name: :external,
      arguments: %{value: "x"},
      description: "external effect"
    }
  end
end
