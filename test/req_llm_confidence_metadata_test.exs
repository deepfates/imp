defmodule Imp.ReqLLMConfidenceMetadataTest do
  use ExUnit.Case, async: true

  defmodule ProviderFixture do
    def generate_text(model, messages, _opts) do
      content = ~s({"category":"Food"})

      {:ok,
       %ReqLLM.Response{
         id: "chatcmpl_fixture",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(content),
         object: %{"category" => "Food"},
         usage: %{input_tokens: 12, output_tokens: 5, total_tokens: 17},
         finish_reason: :stop,
         provider_meta: %{
           "api_type" => "chat_completions",
           "api_key" => "sk-never-retain-this-value",
           :logprobs => [
             %{
               "token" => content,
               "logprob" => -0.2,
               "top_logprobs" => [
                 %{"token" => "Food", "logprob" => -0.2},
                 %{"token" => "sk-secret-alternative-123456", "logprob" => -2.0}
               ]
             }
           ]
         }
       }}
    end
  end

  test "ReqLLM retains only sanitized confidence metadata" do
    lm = Imp.Clients.ReqLLM.new("openai:gpt-fixture", req_module: ProviderFixture)

    assert {:ok, %{__imp_lm_output__: %{"category" => "Food"}, __imp_lm_metadata__: metadata}} =
             Imp.Clients.ReqLLM.generate(lm, [%{role: :user, content: "classify"}], [])

    assert %{
             provider: "openai",
             model: "openai:gpt-fixture",
             api: "chat_completions",
             finish_reason: :stop,
             usage: %{input_tokens: 12, output_tokens: 5, total_tokens: 17},
             content: ~s({"category":"Food"}),
             logprobs: [token]
           } = metadata.req_llm

    assert token.token == ~s({"category":"Food"})
    assert Enum.at(token.top_logprobs, 1).token == "[REDACTED]"
    assert metadata.req_llm.provider_meta["api_key"] == "[REDACTED]"
    assert metadata.req_llm.provider_meta.logprobs == metadata.req_llm.logprobs
    refute inspect(metadata) =~ "sk-never-retain"
    refute inspect(metadata) =~ "sk-secret-alternative"
    refute Map.has_key?(metadata.req_llm, :api_key)
  end
end
