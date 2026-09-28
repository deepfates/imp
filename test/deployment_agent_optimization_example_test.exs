defmodule Imp.DeploymentAgentOptimizationExampleTest do
  use ExUnit.Case, async: false

  @result_path "examples/deployment/evidence/agent-optimization-result.json"
  @artifact_path "examples/deployment/evidence/agent-optimization-artifact.json"

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
        handler: fn messages, _opts ->
          if List.last(messages)[:role] == :tool do
            "Refund queued for A-104"
          else
            %{
              next_thought: "refund the duplicate charge",
              tool_calls: [
                %{
                  id: "billing-1",
                  name: "billing_remediation",
                  arguments: %{account_id: "A-104"}
                }
              ]
            }
          end
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

    assert prediction.metadata[:termination_reason] == :answered
    [event, _answer] = prediction.metadata[:history].messages

    assert Enum.any?(event.tool_call_results, fn result ->
             result.name == "billing_remediation" and result.result == "REFUND_QUEUED:A-104"
           end)
  end

  test "the optimizer record is written when rejections carry failure reasons" do
    dataset = [%{id: 1}, %{id: 2}]

    result =
      Imp.Optimize.Anything.run("base", nil,
        dataset: dataset,
        valset: dataset,
        batch_evaluator: fn pairs -> Enum.map(pairs, fn {_c, ex} -> {0.0, %{id: ex.id}} end) end,
        config:
          Imp.Optimize.Anything.Config.new(
            engine: [max_candidate_proposals: 2, raise_on_exception: false, seed: 1],
            reflection: [
              reflection_minibatch_size: 2,
              module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
                raise "selector saw sk-or-v1-0123456789abcdef0123456789abcdef"
              end
            ]
          ),
        fallback_proposer: fn _candidate, _component, _records, _iteration -> "better" end
      )

    assert [%{reason: {:proposal_error, %RuntimeError{}}} | _] = result.rejected

    result = %{
      result
      | rejected: result.rejected ++ [%{iteration: 3, reason: {:incomplete_evaluation, 1}}]
    }

    record =
      apply(ImpDeployment.AgentOptimization.Runner, :optimizer_record, [result])
      |> then(&Jason.encode!(%{"optimizer" => &1}, pretty: true))

    assert record =~ "incomplete_evaluation"
    assert record =~ "proposal_error"
    refute record =~ "sk-or-v1-"
  end

  test "retained live result binds a useful fresh-applicable Artifact" do
    result = @result_path |> File.read!() |> Jason.decode!()
    artifact_bytes = File.read!(@artifact_path)

    artifact_sha256 =
      "sha256:" <>
        (:crypto.hash(:sha256, artifact_bytes) |> Base.encode16(case: :lower))

    assert result["artifact"] == %{
             "path" => Path.basename(@artifact_path),
             "sha256" => artifact_sha256
           }

    split_ids = result["data"] |> Map.values() |> List.flatten()
    assert length(split_ids) == 10
    assert length(Enum.uniq(split_ids)) == 10
    assert get_in(result, ["held_out", "baseline", "mean_score"]) == 0.95
    assert get_in(result, ["held_out", "selected", "mean_score"]) == 1.0
    assert get_in(result, ["fresh_process", "score"]) == 1.0
    assert get_in(result, ["budgets", "task", "requests"]) == 72
    assert get_in(result, ["budgets", "optimizer", "requests"]) == 3

    refute Regex.match?(
             ~r/(sk-or-v1-|api[_-]?key|authorization|bearer |client[_-]?secret|password)/i,
             File.read!(@result_path) <> artifact_bytes
           )

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "unused"} end)
    program = apply(ImpDeployment.AgentOptimization, :new, [lm])

    selected =
      @artifact_path
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(program)

    assert selected.react.tools.billing_remediation.description ==
             get_in(result, [
               "optimizer",
               "best_candidate",
               "tool/billing_remediation/description"
             ])

    assert selected.react.tools.billing_remediation.run ==
             program.react.tools.billing_remediation.run
  end
end
