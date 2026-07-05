defmodule ProviderStreamingTest do
  use ExUnit.Case

  defmodule SSETransport do
    @behaviour DSPy.HTTP

    @impl true
    def post(_url, _headers, _body, _opts), do: {:error, :unexpected_post}

    @impl true
    def stream(_url, _headers, _body, _opts) do
      [
        ~s(data: {"choices":[{"delta":{"content":"po"}}]}\n\n),
        ~s(data: {"choices":[{"delta":{"content":"ng"},"finish_reason":"stop"}]}\n\n),
        "data: [DONE]\n\n"
      ]
    end
  end

  test "HTTP LM parses OpenAI-style SSE streaming chunks" do
    lm = DSPy.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: SSETransport)
    messages = [%{role: :user, content: "say pong"}]

    events = DSPy.Clients.HTTPLM.stream(lm, messages) |> Enum.to_list()

    assert Enum.map(events, & &1.chunk) |> Enum.reject(&is_nil/1) == ["po", "ng"]
    assert Enum.any?(events, & &1.done)
  end

  test "DSPy.Streaming can use provider stream for Predict programs" do
    lm = DSPy.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: SSETransport)
    program = DSPy.predict("question -> answer", lm: lm)

    text =
      program
      |> DSPy.Streaming.stream(%{question: "say pong"}, provider_stream: true)
      |> Enum.map(& &1.chunk)
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    assert text == "pong"
  end
end
