defmodule ProviderStreamingTest do
  use ExUnit.Case

  defmodule SSETransport do
    @behaviour DSEx.HTTP

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
    ref =
      DSEx.Test.TelemetryHelpers.attach([
        [:dsex, :lm, :stream, :start],
        [:dsex, :lm, :stream, :chunk],
        [:dsex, :lm, :stream, :stop]
      ])

    lm = DSEx.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: SSETransport)
    messages = [%{role: :user, content: "say pong"}]

    events = DSEx.Clients.HTTPLM.stream(lm, messages) |> Enum.to_list()

    assert Enum.map(events, & &1.chunk) |> Enum.reject(&is_nil/1) == ["po", "ng"]
    assert Enum.any?(events, & &1.done)
    assert_received {^ref, [:dsex, :lm, :stream, :start], _, %{lm: %{model: "gpt-test"}}}

    assert_received {^ref, [:dsex, :lm, :stream, :chunk], %{count: 1}, %{chunk: %{chunk: "po"}}}

    assert_received {^ref, [:dsex, :lm, :stream, :stop], %{count: 1}, _}
  end

  test "DSEx.Streaming can use provider stream for Predict programs" do
    lm = DSEx.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: SSETransport)
    program = DSEx.predict("question -> answer", lm: lm)

    text =
      program
      |> DSEx.Streaming.stream(%{question: "say pong"}, provider_stream: true)
      |> Enum.map(& &1.chunk)
      |> Enum.reject(&is_nil/1)
      |> Enum.join()

    assert text == "pong"
  end
end
