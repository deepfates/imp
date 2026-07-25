defmodule Imp.BenchmarkTruth.OpenRouterFreeGuardTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OpenRouterFreeGuard

  defmodule CheckedFixtureLM do
    @behaviour Imp.LM
    defstruct [:budget, :actual_model]

    @impl true
    def generate(_messages, _opts), do: {:error, :checked_fixture_instance_required}

    def generate(%__MODULE__{} = lm, messages, opts) do
      {:ok, reservation} =
        Imp.BenchmarkTruth.CampaignBudget.reserve(lm.budget, messages, opts)

      :ok = Imp.BenchmarkTruth.CampaignBudget.authorize_transport_attempt(lm.budget)
      :ok = Imp.BenchmarkTruth.CampaignBudget.release(lm.budget, reservation)

      {:ok,
       %{
         __imp_lm_output__: "IMP",
         __imp_lm_metadata__: %{
           req_llm: %{
             provider: "openrouter",
             model: lm.actual_model,
             finish_reason: :stop,
             provider_meta: %{"provider" => "MockFree"},
             usage: %{
               "cost" => 0.0,
               total_cost: 0.0,
               input_tokens: 8,
               output_tokens: 1
             }
           }
         }
       }}
    end
  end

  test "passes only with exact serialized guard, one transport attempt, and explicit zero cost" do
    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        assert body["model"] == OpenRouterFreeGuard.model()
        assert get_in(body, ["provider", "max_price", "prompt"]) == 0
        assert get_in(body, ["provider", "allow_fallbacks"]) == false
        assert get_in(body, ["provider", "data_collection"]) == "deny"
        assert get_in(body, ["usage", "include"]) == true
        {200, response(0.0)}
      end)

    assert {:ok, artifact} =
             OpenRouterFreeGuard.run(
               api_key: "local-test-key",
               base_url: base_url,
               catalog_fetcher: &catalog/0
             )

    assert artifact["status"] == "passed"
    assert get_in(artifact, ["budget", "requests"]) == 1
    assert get_in(artifact, ["budget", "transport_attempts"]) == 1
    assert get_in(artifact, ["response_accounting", "actual_model"]) == "openai/gpt-oss-20b"
    assert get_in(artifact, ["response_accounting", "upstream_provider"]) == "MockFree"
    assert get_in(artifact, ["response_accounting", "provider_reported_cost_usd"]) == 0.0
    assert is_nil(get_in(artifact, ["response_accounting", "computed_cost_usd"]))
  end

  test "fails closed when the provider reports a nonzero cost" do
    base_url = Imp.Test.LocalHTTP.start(fn _request -> {200, response(0.01)} end)

    assert {:error, artifact} =
             OpenRouterFreeGuard.run(
               api_key: "local-test-key",
               base_url: base_url,
               catalog_fetcher: &catalog/0
             )

    assert artifact["status"] == "failed"
    assert artifact["error"] =~ "provider_cost"
    assert get_in(artifact, ["budget", "transport_attempts"]) == 1
  end

  test "checked campaign LM halts before another call on model-route drift" do
    {:ok, budget} =
      Imp.BenchmarkTruth.CampaignBudget.start_link(
        limits: %{requests: 2, input_tokens: 10_000, output_tokens: 64, usd: 0.0},
        pricing: %{"input_per_million" => 0.0, "output_per_million" => 0.0},
        default_max_output_tokens: 32
      )

    {:ok, ledger} = OpenRouterFreeGuard.start_ledger()

    checked = %OpenRouterFreeGuard.CheckedLM{
      inner: %CheckedFixtureLM{budget: budget, actual_model: "paid/model"},
      budget: budget,
      ledger: ledger
    }

    assert {:error, {:openrouter_free_validation_failed, _reason}} =
             Imp.LM.generate(checked, [%{role: :user, content: "hello"}], max_tokens: 32)

    first = Imp.BenchmarkTruth.CampaignBudget.snapshot(budget)
    assert first["requests"] == 1
    assert first["transport_attempts"] == 1

    ledger_snapshot = OpenRouterFreeGuard.ledger_snapshot(ledger)
    assert ledger_snapshot["halted"] != nil
    assert [failed_response] = ledger_snapshot["responses"]
    assert failed_response["status"] == "failed"
    assert failed_response["actual_model"] == "paid/model"
    assert failed_response["upstream_provider"] == "MockFree"
    assert failed_response["finish_reason"] == "stop"
    assert failed_response["logical_requests"] == 1
    assert failed_response["transport_attempts"] == 1
    assert failed_response["provider_reported_cost_usd"] == 0.0
    assert failed_response["computed_cost_usd"] == 0.0
    assert is_binary(failed_response["raw_response_sha256"])
    assert is_binary(failed_response["bounded_safe_excerpt"])

    assert {:error, {:openrouter_free_campaign_halted, _reason}} =
             Imp.LM.generate(checked, [%{role: :user, content: "again"}], max_tokens: 32)

    assert Imp.BenchmarkTruth.CampaignBudget.snapshot(budget) == first
  end

  defp catalog do
    %{
      "data" => [
        %{
          "id" => OpenRouterFreeGuard.model(),
          "canonical_slug" => "openai/gpt-oss-20b",
          "pricing" => %{"prompt" => "0", "completion" => "0"}
        }
      ]
    }
  end

  defp response(cost) do
    %{
      "id" => "generation-test",
      "model" => "openai/gpt-oss-20b",
      "provider" => "MockFree",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => "IMP"}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 8,
        "completion_tokens" => 1,
        "total_tokens" => 9,
        "cost" => cost
      }
    }
  end
end
