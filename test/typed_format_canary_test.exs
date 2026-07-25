defmodule Imp.BenchmarkTruth.TypedFormatCanaryTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{OpenRouterFreeGuard, TypedFormatCanary}

  @manifest "benchmarks/config/openrouter-free-typed-format-canary-v1.json"

  test "locally proves every candidate request and content/reasoning mapping" do
    parent = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn request ->
        body = Jason.decode!(request.body)
        send(parent, {:serialized_request, body})

        assert String.ends_with?(body["model"], ":free")
        assert body["provider"] == stringify(OpenRouterFreeGuard.provider_guard())
        assert body["usage"] == %{"include" => true}
        assert get_in(body, ["response_format", "type"]) == "json_schema"
        assert get_in(body, ["response_format", "json_schema", "strict"]) == true

        schema = get_in(body, ["response_format", "json_schema", "schema"])
        assert schema["required"] == ["status"]
        assert get_in(schema, ["properties", "status", "enum"]) == ["ok"]

        {200, response(body["model"])}
      end)

    catalog =
      @manifest
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("candidates")
      |> Map.new(fn candidate ->
        {candidate["id"],
         %{
           "model" => candidate["id"],
           "canonical_model" => String.replace_suffix(candidate["id"], ":free", ""),
           "pricing" => %{"prompt" => 0.0, "completion" => 0.0},
           "supported_parameters" => candidate["catalog_supported_parameters"],
           "checked_url" => "local no-network fixture"
         }}
      end)

    artifact =
      TypedFormatCanary.run(
        api_key: "not-used",
        manifest: @manifest,
        base_url: base_url,
        catalog: catalog
      )

    assert artifact["summary"]["candidate_count"] == 3
    assert artifact["summary"]["format_completed_count"] == 3
    refute artifact["summary"]["optimizer_effectiveness_established"]

    assert artifact["summary"]["recommended_candidate"] ==
             "google/gemma-4-26b-a4b-it:free"

    assert_received {:serialized_request, gemma_request}
    assert gemma_request["model"] == "google/gemma-4-26b-a4b-it:free"
    assert gemma_request["max_tokens"] == 128
    assert gemma_request["reasoning_effort"] == nil

    assert_received {:serialized_request, nemotron_request}
    assert nemotron_request["model"] == "nvidia/nemotron-nano-9b-v2:free"
    assert nemotron_request["max_tokens"] == 128
    assert nemotron_request["reasoning_effort"] == nil

    assert_received {:serialized_request, gpt_request}
    assert gpt_request["model"] == "openai/gpt-oss-20b:free"
    assert gpt_request["max_tokens"] == 512
    assert gpt_request["reasoning_effort"] == "low"

    Enum.each(artifact["results"], fn result ->
      assert result["request_validation"]["passed"]
      assert result["format_status"]["passed"]
      assert result["result"] == %{"status" => "typed", "prediction" => %{"status" => "ok"}}
      assert result["budget"]["requests"] == 1
      assert result["budget"]["transport_attempts"] == 1
      assert get_in(result, ["budget", "usage", "usd"]) == 0.0

      assert [response] = get_in(result, ["response_accounting", "responses"])
      assert response["status"] == "passed"
      assert response["finish_reason"] == "stop"
      assert response["native_reasoning_present"]
      assert response["native_reasoning_bytes"] == byte_size("synthetic reasoning")
      assert response["bounded_native_reasoning_excerpt"] =~ "synthetic reasoning"
      assert response["reasoning_tokens"] == 5
      assert response["reasoning_details_count"] == 0
      assert response["bounded_safe_excerpt"] =~ "status"
      assert response["logical_requests"] == 1
      assert response["transport_attempts"] == 1
      assert response["provider_reported_cost_usd"] == 0.0
      assert response["computed_cost_usd"] == 0.0
    end)
  end

  defp response(model) do
    %{
      "id" => "typed-format-local",
      "model" => model,
      "provider" => "MockFree",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => ~s({"status":"ok"}),
            "reasoning" => "synthetic reasoning"
          }
        }
      ],
      "usage" => %{
        "prompt_tokens" => 12,
        "completion_tokens" => 12,
        "total_tokens" => 24,
        "completion_tokens_details" => %{"reasoning_tokens" => 5},
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
