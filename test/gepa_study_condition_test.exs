defmodule Imp.BenchmarkTruth.GepaStudyConditionTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.GepaStudyCondition

  @ifbench_root "tmp/gepa-six-task-current-root"

  defmodule NeverLM do
    defstruct []

    def generate(_messages, _opts), do: raise("provider call was not expected")
    def generate(_lm, _messages, _opts), do: raise("provider call was not expected")
  end

  defmodule SafetyLM do
    defstruct []

    def generate(_messages, _opts), do: raise(safety_error())
    def generate(_lm, _messages, _opts), do: raise(safety_error())

    defp safety_error do
      %Imp.OperationalSafetyError{
        kind: :budget,
        message: "provider-disabled compile boundary",
        reason: :provider_disabled_compile_boundary
      }
    end
  end

  @root "tmp/gepa-six-task-current-root"

  @tag :evidence_infrastructure
  test "constructs exact Heavy MIPRO and pinned merge GEPA treatments without providers" do
    lm = %NeverLM{}

    prepared =
      GepaStudyCondition.prepare!(
        @root,
        "AIMEBench",
        %{task: lm, reflection: lm, judge: lm},
        max_concurrency: 8
      )

    mipro = GepaStudyCondition.optimizer!(:mipro_v2_heavy, prepared, 17)
    assert mipro.config.auto == :heavy
    assert mipro.config.proposer_fidelity == :dspy_3_2_1
    assert mipro.config.search_fidelity == :dspy_3_2_1_optuna_4_9_0
    assert mipro.config.program_aware_proposer
    assert mipro.max_errors == 10_000
    assert mipro.max_concurrency == 8

    gepa = GepaStudyCondition.optimizer!(:gepa_v0_1_4_merge, prepared, 17)
    assert gepa.execution_profile == :gepa_v0_1_4_merge
    assert gepa.max_metric_calls == 1_839
    assert gepa.max_reflection_calls == 1_196
    assert gepa.minibatch_size == 3
    assert gepa.module_selector == :round_robin
    assert gepa.use_merge
    assert gepa.max_concurrency == 8
    assert prepared.outer_max_concurrency == 8

    assert prepared.loaded.test_count == 150
    refute Map.has_key?(prepared.loaded, :test)
  end

  @tag :evidence_infrastructure
  test "nonbaseline optimize paths reach execution with the declared arm" do
    lm = %SafetyLM{}

    prepared =
      GepaStudyCondition.prepare!(@root, "AIMEBench", %{
        task: lm,
        reflection: lm,
        judge: lm
      })

    for arm <- [:mipro_v2_heavy, :gepa_v0_1_4_merge] do
      assert_raise Imp.OperationalSafetyError, ~r/provider-disabled compile boundary/, fn ->
        GepaStudyCondition.optimize!(arm, prepared, 17)
      end
    end
  end

  @tag :evidence_infrastructure
  test "exact Heavy IFBench setup crosses real ReqLLM parsing and emits a resumable checkpoint" do
    owner = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        send(owner, {:heavy_wire, body})
        prompt = body["messages"] |> Enum.map_join("\n", & &1["content"])

        markers =
          ~r/\[\[ ## ([a-z_]+) ## \]\]/
          |> Regex.scan(prompt, capture: :all_but_first)
          |> List.flatten()
          |> Enum.reject(&(&1 in ["completed", "reasoning"]))

        field = List.last(markers) || "response"

        reasoning =
          if String.contains?(prompt, "[[ ## reasoning ## ]]") do
            "[[ ## reasoning ## ]]\nprovider-disabled reasoning\n\n"
          else
            ""
          end

        content =
          reasoning <>
            "[[ ## #{field} ## ]]\nprovider-disabled #{field}\n\n[[ ## completed ## ]]"

        {200,
         %{
           "id" => "heavy-provider-disabled",
           "object" => "chat.completion",
           "model" => "heavy-provider-disabled",
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant", "content" => content},
               "finish_reason" => "stop"
             }
           ],
           "usage" => %{
             "prompt_tokens" => 1,
             "completion_tokens" => 1,
             "total_tokens" => 2,
             "cost" => 0.0
           }
         }}
      end)

    lm =
      Imp.req_llm(
        %{
          provider: :openai,
          id: "heavy-provider-disabled",
          model: "heavy-provider-disabled",
          base_url: base_url <> "/v1"
        },
        api_key: "provider-disabled",
        cache: false,
        temperature: 1.0,
        max_tokens: 16_384,
        max_retries: 0
      )

    prepared =
      GepaStudyCondition.prepare!(
        @ifbench_root,
        "IFBench",
        %{task: lm, reflection: lm, judge: lm},
        max_concurrency: 2
      )

    checkpoint_owner = self()

    optimized =
      GepaStudyCondition.optimize!(:mipro_v2_heavy, prepared, 2_026_080_101,
        max_trials: 0,
        checkpoint_fn: fn checkpoint ->
          send(checkpoint_owner, {:heavy_checkpoint, checkpoint})
        end
      )

    assert_receive {:heavy_checkpoint, checkpoint}
    assert is_map(checkpoint)
    assert checkpoint == optimized.report.metadata.resume_state
    assert optimized.report.metadata.run_status == :paused
    assert optimized.report.metadata.proposals.generate_response_module.status == :ok
    assert optimized.report.metadata.proposals.ensure_correct_response_module.status == :ok
    assert optimized.report.metadata.proposals.generate_response_module.errors == []
    assert optimized.report.metadata.proposals.ensure_correct_response_module.errors == []

    wires = collect_heavy_wires([])
    assert length(wires) > 65
    refute Enum.any?(wires, &Map.has_key?(&1, "max_depth"))

    resumed =
      GepaStudyCondition.optimize!(:mipro_v2_heavy, prepared, 2_026_080_101,
        max_trials: 0,
        resume_state: checkpoint
      )

    assert resumed.report.metadata.run_status == :paused
    assert resumed.report.metadata.resumed

    assert resumed.report.metadata.resume_state["payload"]["compatibility"] ==
             checkpoint["payload"]["compatibility"]

    assert resumed.report.metadata.resume_state["payload"]["state"] ==
             checkpoint["payload"]["state"]

    assert collect_heavy_wires([]) == []
  end

  @tag :evidence_infrastructure
  test "each declared arm opens and evaluates heldout exactly once" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(counter, &(&1 + 1))
          %{reasoning: "fixture", answer: "0"}
        end
      )

    prepared =
      GepaStudyCondition.prepare!(@root, "AIMEBench", %{
        task: lm,
        reflection: lm,
        judge: lm
      })

    baseline = GepaStudyCondition.optimize!(:baseline, prepared, 17)
    result = GepaStudyCondition.heldout!(:baseline, prepared, baseline)

    assert result.arm == :baseline
    assert result.test_count == 150
    assert length(result.result.rows) == 150
    assert Agent.get(counter, & &1) == 150

    result = GepaStudyCondition.heldout!(:mipro_v2_heavy, prepared, baseline)

    assert result.arm == :mipro_v2_heavy
    assert result.test_count == 150
    assert length(result.result.rows) == 150
    assert Agent.get(counter, & &1) == 300
  end

  defp collect_heavy_wires(acc) do
    receive do
      {:heavy_wire, body} -> collect_heavy_wires([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
