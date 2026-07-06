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
    Process.put(:dsex_telemetry_handler, fn event, measurements, metadata ->
      send(self(), {:telemetry, event, measurements, metadata})
    end)

    lm = DSEx.Clients.OpenAI.new("gpt-test", api_key: "sk-test", transport: SSETransport)
    messages = [%{role: :user, content: "say pong"}]

    events = DSEx.Clients.HTTPLM.stream(lm, messages) |> Enum.to_list()

    assert Enum.map(events, & &1.chunk) |> Enum.reject(&is_nil/1) == ["po", "ng"]
    assert Enum.any?(events, & &1.done)
    assert_received {:telemetry, [:dsex, :lm, :stream, :start], _, %{lm: %{model: "gpt-test"}}}

    assert_received {:telemetry, [:dsex, :lm, :stream, :chunk], %{count: 1},
                     %{chunk: %{chunk: "po"}}}

    assert_received {:telemetry, [:dsex, :lm, :stream, :stop], %{count: 1}, _}
  after
    Process.delete(:dsex_telemetry_handler)
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
