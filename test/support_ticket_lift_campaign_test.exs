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

  test "v2 preregistration changes only the bounded output envelope" do
    path = "benchmarks/config/support-ticket-lift-openrouter-free-v2.json"

    manifest =
      path
      |> File.read!()
      |> Jason.decode!()

    design = manifest["frozen_design"]

    assert manifest["status"] == "preregistered_not_run"
    assert manifest["authorization"] == "not_launched"
    assert get_in(manifest, ["predecessor", "disposition"]) == "frozen_stopped_incomplete"

    predecessor_sha =
      "benchmarks/results/support-ticket-lift-openrouter-free-20260725.json"
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert predecessor_sha == get_in(manifest, ["predecessor", "sha256"])

    assert get_in(manifest, ["predecessor", "observed", "truncation_assessment"]) ==
             "plausible_but_unknown"

    assert design["seeds"] == [17, 23, 31]
    assert Enum.map(design["arms"], & &1["id"]) == ["baseline", "labeled_few_shot"]

    assert get_in(design, ["arms", Access.at(1), "options"]) == %{
             "k" => 8,
             "sample" => true,
             "seed" => "campaign_seed"
           }

    assert get_in(design, ["dataset", "untouched_test_indices"]) ==
             [0, 1, 5, 6, 10, 11, 15, 16]

    assert get_in(design, ["execution", "logical_request_limit"]) == 48
    assert get_in(design, ["execution", "transport_attempt_limit"]) == 48
    assert get_in(design, ["execution", "max_concurrency"]) == 1
    assert get_in(design, ["execution", "json_retries"]) == 0
    assert get_in(design, ["execution", "transport_retries"]) == 0
    assert get_in(design, ["execution", "max_output_tokens"]) == 256

    assert get_in(design, ["execution", "max_output_tokens_change_from_v1"]) ==
             "64_to_256_only"

    v2_options = SupportTicketLiftCampaign.v2_options!(path)
    assert v2_options[:max_output_tokens] == 256

    factory = fn _seed, budget, ledger ->
      budgeted = %BudgetedLM{
        inner: %LengthLimitedMalformedLM{budget: budget, output_tokens: 256},
        budget: budget,
        max_output_tokens: 256
      }

      %OpenRouterFreeGuard.CheckedLM{inner: budgeted, budget: budget, ledger: ledger}
    end

    artifact =
      [
        runtime: :openrouter_free,
        api_key: "not-used",
        catalog: %{"source" => "local no-network fixture"},
        lm_factory: factory
      ]
      |> Keyword.merge(v2_options)
      |> SupportTicketLiftCampaign.run()

    assert artifact["campaign"] == manifest["campaign_id"]
    assert artifact["protocol_manifest"]["sha256"] != nil
    assert artifact["controls"]["max_output_tokens"] == 256
    assert artifact["budget"]["limits"]["output_tokens"] == 48 * 256
    assert artifact["budget"]["requests"] == 1
    assert artifact["budget"]["transport_attempts"] == 1
    assert get_in(artifact, ["summary", "stopped_provider_context", "output_tokens"]) == 256
    assert get_in(artifact, ["summary", "stopped_provider_context", "finish_reason"]) == "length"
  end

  test "v3 preregistration preserves the benchmark and selects only the format-qualified route" do
    manifest =
      "benchmarks/config/support-ticket-lift-openrouter-free-v3.json"
      |> File.read!()
      |> Jason.decode!()

    design = manifest["frozen_design"]

    assert manifest["status"] == "preregistered_not_run"
    assert manifest["authorization"] == "not_launched"

    assert Enum.all?(
             manifest["closed_predecessors"],
             &(&1["disposition"] == "permanently_closed_stopped_incomplete")
           )

    canary_path = get_in(manifest, ["format_qualification", "artifact"])

    canary_sha =
      canary_path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert canary_sha == get_in(manifest, ["format_qualification", "sha256"])

    assert get_in(manifest, ["format_qualification", "selected_candidate"]) ==
             "google/gemma-4-26b-a4b-it:free"

    assert design["seeds"] == [17, 23, 31]
    assert Enum.map(design["arms"], & &1["id"]) == ["baseline", "labeled_few_shot"]

    assert get_in(design, ["arms", Access.at(1), "options"]) == %{
             "k" => 8,
             "sample" => true,
             "seed" => "campaign_seed"
           }

    assert get_in(design, ["dataset", "untouched_test_indices"]) ==
             [0, 1, 5, 6, 10, 11, 15, 16]

    assert get_in(design, ["model", "requested"]) == "google/gemma-4-26b-a4b-it:free"
    assert get_in(design, ["execution", "logical_request_limit"]) == 48
    assert get_in(design, ["execution", "transport_attempt_limit"]) == 48
    assert get_in(design, ["execution", "max_concurrency"]) == 1
    assert get_in(design, ["execution", "json_retries"]) == 0
    assert get_in(design, ["execution", "transport_retries"]) == 0
    assert get_in(design, ["execution", "max_output_tokens"]) == 128

    assert get_in(design, ["response_format", "type"]) == "json_schema"
    assert get_in(design, ["response_format", "json_schema", "strict"])

    schema = get_in(design, ["response_format", "json_schema", "schema"])
    assert schema["required"] == ["team"]
    assert schema["additionalProperties"] == false

    assert get_in(schema, ["properties", "team", "enum"]) ==
             ["atlas", "harbor", "beacon", "quill"]
  end
end
