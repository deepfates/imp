defmodule Imp.BenchmarkTruth.SupportTicketLiftCampaignTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{
    BudgetedLM,
    CampaignBudget,
    OpenRouterFreeGuard,
    SupportTicketLiftCampaign
  }

  defmodule LengthLimitedMalformedLM do
    @behaviour Imp.LM

    defstruct [:budget, output_tokens: 64]

    @impl true
    def generate(_messages, _opts), do: {:error, :length_limited_fixture_instance_required}

    def generate(%__MODULE__{budget: budget, output_tokens: output_tokens}, _messages, _opts) do
      :ok = CampaignBudget.authorize_transport_attempt(budget)

      {:ok,
       %{
         __imp_lm_output__: ~s({"team":),
         __imp_lm_metadata__: %{
           req_llm: %{
             provider: "openrouter",
             model: OpenRouterFreeGuard.model(),
             provider_meta: %{"provider" => "MockFree"},
             finish_reason: :length,
             usage: %{
               "cost" => 0.0,
               total_cost: 0.0,
               input_tokens: 287,
               output_tokens: output_tokens
             }
           }
         }
       }}
    end
  end

  test "runs three paired seeds without exposing test rows to compilation" do
    factory = fn _seed, budget, _ledger ->
      inner = Imp.LM.Static.new(handler: fn _messages, _opts -> %{team: "atlas"} end)
      %BudgetedLM{inner: inner, budget: budget, max_output_tokens: 64}
    end

    artifact =
      SupportTicketLiftCampaign.run(
        runtime: :local,
        model: "static:test",
        model_metadata: %{"fixture" => true},
        lm_factory: factory
      )

    assert artifact["summary"]["execution_complete"]
    refute artifact["summary"]["c3_effectiveness_established"]
    refute artifact["summary"]["within_task_numeric_go_rule_passed"]
    assert artifact["summary"]["mean_test_lift"] == 0.0
    assert length(artifact["results"]) == 6
    assert Enum.all?(artifact["results"], &(&1["test_score"] == 0.25))
    assert Enum.all?(artifact["results"], &(length(&1["test_rows"]) == 8))

    assert artifact["budget"]["requests"] == SupportTicketLiftCampaign.expected_requests()
    assert artifact["budget"]["transport_attempts"] == 0
    assert get_in(artifact, ["dataset", "untouched_test_rows_used"]) == 8
    assert get_in(artifact, ["controls", "test_visible_to_optimizer_or_selection"]) == false

    [baseline, labeled | _] = artifact["results"]
    assert baseline["program"]["demo_count"] == 0
    assert labeled["program"]["demo_count"] == 8
    assert baseline["selection_split"] == "none"
    assert labeled["selection_split"] == "train"
  end

  test "free-provider design cannot silently expand past the 48-call preregistration" do
    assert_raise ArgumentError, ~r/pinned to eight balanced test rows/, fn ->
      SupportTicketLiftCampaign.run(
        runtime: :openrouter_free,
        api_key: "not-used",
        test_limit: 9,
        lm_factory: fn _, _, _ -> flunk("LM factory must not run") end
      )
    end
  end

  test "retains typed decoder and provider evidence when strict evaluation cancels" do
    factory = fn _seed, budget, ledger ->
      budgeted = %BudgetedLM{
        inner: %LengthLimitedMalformedLM{budget: budget},
        budget: budget,
        max_output_tokens: 64
      }

      %OpenRouterFreeGuard.CheckedLM{inner: budgeted, budget: budget, ledger: ledger}
    end

    artifact =
      SupportTicketLiftCampaign.run(
        runtime: :openrouter_free,
        api_key: "not-used",
        catalog: %{"source" => "local no-network fixture"},
        lm_factory: factory
      )

    assert [failure] = artifact["results"]
    assert failure["status"] == "failed"
    assert failure["failure_detail"]["type"] == "evaluation_cancelled"

    assert [%{"index" => 0, "reason" => decoder_reason} = structured_error] =
             failure["failure_detail"]["adapter_or_program_errors"]

    assert structured_error["category"] == "adapter_decode"
    assert structured_error["reason_type"] == "Imp.AdapterParseError"
    assert structured_error["message"] =~ "JSON object"
    assert decoder_reason =~ "team"

    provider = failure["provider_failure_context"]
    assert provider["status"] == "passed"
    assert provider["gateway_provider"] == "openrouter"
    assert provider["upstream_provider"] == "MockFree"
    assert provider["actual_model"] == OpenRouterFreeGuard.model()
    assert provider["logical_requests"] == 1
    assert provider["transport_attempts"] == 1
    assert provider["provider_reported_cost_usd"] == 0.0
    assert provider["computed_cost_usd"] == 0.0
    assert provider["finish_reason"] == "length"
    assert provider["requested_max_output_tokens"] == 64
    assert provider["truncation_indicators"]["finish_reason_is_length"]
    assert provider["truncation_indicators"]["output_tokens_reached_ceiling"]
    assert "sha256:" <> digest = provider["raw_response_sha256"]
    assert byte_size(digest) == 64
    assert provider["bounded_safe_excerpt"] =~ "team"

    assert artifact["summary"]["execution_complete"] == false
    assert artifact["summary"]["stopped_failure"] == failure["failure_detail"]
    assert artifact["summary"]["stopped_provider_context"] == provider
    assert artifact["budget"]["requests"] == 1
    assert artifact["budget"]["transport_attempts"] == 1
  end

  defp v3_response(model) do
    %{
      "id" => "support-v3-local",
      "model" => model,
      "provider" => "MockFree",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => ~s({"team":"atlas"})}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 20,
        "completion_tokens" => 5,
        "total_tokens" => 25,
        "completion_tokens_details" => %{"reasoning_tokens" => 0},
        "cost" => 0.0,
        "total_cost" => 0.0
      }
    }
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
