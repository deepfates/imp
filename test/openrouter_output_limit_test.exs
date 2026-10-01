defmodule Imp.OpenRouterOutputLimitTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true

  # A refusal lets both ordinary and streamed requests reach the real HTTP
  # boundary without needing a completion fixture. These assertions concern
  # the request, not whether an actual provider completes it.
  defp capture(provider, mode, configured \\ [], per_call \\ []) do
    owner = self()
    ref = make_ref()

    url =
      Imp.Test.LocalHTTP.start(fn request ->
        send(owner, {ref, Jason.decode!(request.body)})
        {400, %{"error" => %{"message" => "fixture: request captured", "code" => 400}}}
      end)

    lm =
      Imp.req_llm(
        %{
          provider: provider,
          id: "fixture/model",
          model: "fixture/model",
          base_url: url <> "/v1",
          limits: %{context: 500_000, output: 450_000}
        },
        Keyword.merge(
          [api_key: "fixture", cache: false, req_http_options: [retry: false]],
          configured
        )
      )

    messages = [%{role: :user, content: "A request with no caller output reservation."}]

    case mode do
      :generate ->
        assert {:error, %Imp.LMError{status: 400}} =
                 Imp.Clients.ReqLLM.generate(lm, messages, per_call)

      :stream ->
        lm |> Imp.Clients.ReqLLM.stream(messages, per_call) |> Enum.to_list()
    end

    assert_receive {^ref, body}
    assert body["stream"] == (mode == :stream)
    body
  end

  for mode <- [:generate, :stream] do
    test "#{mode}: OpenRouter leaves an unspecified output limit to the endpoint" do
      body = capture(:openrouter, unquote(mode))
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
      refute Map.has_key?(body, "max_output_tokens")
    end

    test "#{mode}: OpenRouter preserves an explicit limit and its per-call override" do
      assert capture(:openrouter, unquote(mode), max_tokens: 512)["max_tokens"] == 512

      assert capture(:openrouter, unquote(mode), [max_tokens: 512], max_tokens: 256)[
               "max_tokens"
             ] == 256
    end

    test "#{mode}: another provider keeps its catalog default" do
      assert capture(:openai, unquote(mode))["max_tokens"] == 450_000
    end
  end

  test "stream: the caller's Finch callback sees the request with the omitted limit" do
    owner = self()

    body =
      capture(:openrouter, :stream,
        on_finch_request: fn request ->
          send(owner, {:callback, Jason.decode!(request.body)})
          request
        end
      )

    assert_receive {:callback, ^body}
    refute Map.has_key?(body, "max_tokens")
  end

  test "generate: the caller's request step can set its own output limit" do
    owner = self()

    plugin = fn request ->
      Req.Request.append_request_steps(request,
        caller_output_limit: fn request ->
          body = Jason.decode!(request.body)
          send(owner, {:before_override, body})
          %{request | body: Jason.encode!(Map.put(body, "max_tokens", 128))}
        end
      )
    end

    body = capture(:openrouter, :generate, req_http_options: [retry: false, plugins: [plugin]])
    assert_receive {:before_override, original}
    refute Map.has_key?(original, "max_tokens")
    assert body["max_tokens"] == 128
  end
end
