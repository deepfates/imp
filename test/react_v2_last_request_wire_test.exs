defmodule Imp.ReActV2LastRequestWireTest do
  use ExUnit.Case

  # The last request of an interrupted turn says `tool_choice: "none"` and
  # keeps the roster every step sent. What that means on the wire is the
  # provider's encoding, so each provider path is run through the real ReqLLM
  # request stack against a local server and the encoded body is read back.

  @providers [
    {:openai, "/v1", "none"},
    {:openrouter, "", "none"},
    {:anthropic, "", %{"type" => "none"}}
  ]

  for {provider, prefix, expected_choice} <- @providers do
    test "#{provider} encodes the last request as tool_choice none with the same tools" do
      provider = unquote(provider)
      {:ok, bodies} = Agent.start_link(fn -> [] end)

      url =
        Imp.Test.LocalHTTP.start(fn request ->
          body = Jason.decode!(request.body)
          n = Agent.get_and_update(bodies, &{length(&1), &1 ++ [body]})
          {200, response(provider, body["model"], n)}
        end)

      lm =
        Imp.req_llm(
          %{
            provider: provider,
            id: "fixture",
            model: "fixture",
            base_url: url <> unquote(prefix)
          },
          api_key: "fixture",
          cache: false,
          req_http_options: [retry: false, max_retries: 0]
        )

      look = Imp.tool(:look, "Look at a thing", fn _arguments -> "it is there" end)
      program = Imp.react_v2("intent -> answer", [look], lm: lm, max_iters: 1)

      assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
      assert Imp.get(prediction, :answer) == "It is there."
      assert Imp.get(prediction, :termination_reason) == :last_prose

      [first, last] = Agent.get(bodies, & &1)
      assert last["tool_choice"] == unquote(Macro.escape(expected_choice))
      assert first["tool_choice"] != last["tool_choice"]
      assert [%{} | _] = last["tools"]
      assert last["tools"] == first["tools"]
    end
  end

  defp response(:anthropic, model, 0) do
    %{
      "id" => "msg_1",
      "type" => "message",
      "role" => "assistant",
      "model" => model,
      "content" => [%{"type" => "tool_use", "id" => "toolu_1", "name" => "look", "input" => %{}}],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp response(:anthropic, model, _n) do
    %{
      "id" => "msg_2",
      "type" => "message",
      "role" => "assistant",
      "model" => model,
      "content" => [%{"type" => "text", "text" => "It is there."}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
  end

  defp response(_chat, model, 0) do
    chat(model, %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{"name" => "look", "arguments" => "{}"}
        }
      ]
    })
  end

  defp response(_chat, model, _n),
    do: chat(model, %{"role" => "assistant", "content" => "It is there."})

  defp chat(model, message) do
    %{
      "id" => "chat",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => message,
          "finish_reason" => if(message["tool_calls"], do: "tool_calls", else: "stop")
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end
end
