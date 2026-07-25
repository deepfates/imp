defmodule Imp.BenchmarkTruth.OpenRouterFreeGuardTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OpenRouterFreeGuard

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
