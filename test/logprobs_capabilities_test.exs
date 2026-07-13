defmodule DSEx.LogprobsCapabilitiesTest do
  use ExUnit.Case, async: true

  test "extracts the exact joint overlap and resolves enum alternatives" do
    content = ~s({"category":"Bars and pubs"})

    logprobs = [
      %{
        "token" => ~s({"category":"Ba),
        "logprob" => -0.1,
        "top_logprobs" => [
          %{"token" => "Bars", "logprob" => -0.1},
          %{"token" => "Food", "logprob" => -2.0}
        ]
      },
      %{"token" => "rs and", "logprob" => -0.2, "top_logprobs" => []},
      %{"token" => ~s( pubs"}), "logprob" => -0.3, "top_logprobs" => []}
    ]

    assert {:ok, extraction} =
             DSEx.Logprobs.extract(content, logprobs, "category", [
               "Bars and pubs",
               "Food and dining"
             ])

    assert extraction.value == "Bars and pubs"
    assert_in_delta extraction.joint_logprob, -0.6, 1.0e-12
    assert_in_delta extraction.raw_confidence, :math.exp(-0.6), 1.0e-12
    assert Enum.map(extraction.tokens, & &1.token) == [~s({"category":"Ba), "rs and", ~s( pubs"})]

    assert [bars, food] = extraction.top_alternatives
    assert bars.resolved_value == "Bars and pubs"
    assert food.resolved_value == "Food and dining"
  end

  test "empty overlap is unavailable rather than misleading numeric zero" do
    content = ~s({"category":""})
    logprobs = [%{token: content, logprob: -0.2, top_logprobs: []}]

    assert {:error, :no_overlapping_logprob_tokens} =
             DSEx.Logprobs.extract(content, logprobs, :category, [""])
  end

  test "provider capabilities require returned OpenAI Chat logprobs" do
    assert :ok =
             DSEx.Capabilities.token_logprobs(%{
               req_llm: %{provider: "openai", api: "chat_completions", logprobs: [%{}]}
             })

    assert {:error, :missing_logprobs} =
             DSEx.Capabilities.token_logprobs(%{
               req_llm: %{provider: "openai", api: "chat_completions", logprobs: []}
             })

    assert {:error, :openai_responses_unsupported} =
             DSEx.Capabilities.token_logprobs(%{
               req_llm: %{provider: "openai", api: "responses", logprobs: [%{}]}
             })

    assert {:error, :anthropic_unsupported} =
             DSEx.Capabilities.token_logprobs(%{req_llm: %{provider: "anthropic"}})

    assert {:error, :gemini_unsupported} =
             DSEx.Capabilities.token_logprobs(%{req_llm: %{provider: "google"}})

    assert {:error, :missing_provider_metadata} = DSEx.Capabilities.token_logprobs(%{})
  end
end
