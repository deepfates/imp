defmodule Imp.DeploymentAgentOptimizationExampleTest do
  use ExUnit.Case, async: false

  setup_all do
    previous = System.get_env("IMP_AGENT_OPT_NO_RUN")
    System.put_env("IMP_AGENT_OPT_NO_RUN", "1")
    Code.require_file("examples/deployment/agent_optimization.exs", File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_AGENT_OPT_NO_RUN", previous),
        else: System.delete_env("IMP_AGENT_OPT_NO_RUN")
    end)

    :ok
  end

  test "packaged agent story applies descriptions without replacing trusted tools" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "refund the duplicate charge",
            tool_calls: [
              %{
                id: "billing-1",
                name: "billing_remediation",
                arguments: %{account_id: "A-104"}
              },
              %{id: "submit-1", name: "submit", arguments: %{answer: "Refund queued for A-104"}}
            ]
          }
        end
      )

    original = apply(ImpDeployment.AgentOptimization, :new, [lm])
    values = Imp.ProgramParameters.values(original)

    assert Map.keys(values) |> Enum.sort() == [
             "tool/account_lookup/description",
             "tool/billing_remediation/description",
             "tool/security_response/description"
           ]

    updated =
      Imp.ProgramParameters.apply_values!(original, %{
        values
        | "tool/billing_remediation/description" =>
            "Queue refunds only for explicit duplicate billing disputes."
      })

    assert updated.react.tools.billing_remediation.description =~ "duplicate billing"

    assert updated.react.tools.billing_remediation.run ==
             original.react.tools.billing_remediation.run

    assert {:ok, prediction} = Imp.call(updated, %{request: "Refund duplicate charge on A-104"})
    assert Imp.get(prediction, :answer) == "Refund queued for A-104"

    [event] = Imp.get(prediction, :history).messages

    assert Enum.any?(event.tool_call_results, fn result ->
             result.name == "billing_remediation" and result.result == "REFUND_QUEUED:A-104"
           end)
  end
end
