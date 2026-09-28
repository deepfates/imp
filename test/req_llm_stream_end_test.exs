defmodule Imp.ReqLLMStreamEndTest do
  use ExUnit.Case, async: true

  alias Imp.Streaming.Messages.StreamResponse

  # These streams come from ReqLLM itself, decoding server-sent events from a
  # local server, so they end the way a provider's stream does: as a
  # `Stream.resource` that has run out, not as a list.

  @content %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => "pong"}}]
  }

  @finish %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
  }

  @usage %{
    "id" => "gen-1",
    "model" => "local-model",
    "choices" => [],
    "usage" => %{
      "prompt_tokens" => 7,
      "completion_tokens" => 1,
      "total_tokens" => 8,
      "cost" => 0.00042
    }
  }

  defp sse(events, done? \\ true) do
    body = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
    if done?, do: body <> "data: [DONE]\n\n", else: body
  end

  defp lm(body) do
    url = Imp.Test.LocalHTTP.start(fn _request -> {200, body} end)

    Imp.req_llm(
      %{
        provider: :openrouter,
        id: "local-model",
        model: "local-model",
        base_url: url <> "/api/v1"
      },
      api_key: "local-test-key",
      cache: false
    )
  end

  defp stream(lm),
    do: lm |> Imp.Clients.ReqLLM.stream([%{role: :user, content: "ping"}], []) |> Enum.to_list()

  test "a provider stream that runs to its end closes with one done event carrying usage and cost" do
    events = stream(lm(sse([@content, @finish, @usage])))

    assert [%StreamResponse{chunk: "pong", done: false}, %StreamResponse{done: true} = last] =
             events

    assert last.chunk == nil
    assert last.metadata.finish_reason == :stop
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = last.metadata.usage
    assert last.metadata.usage["cost"] == 0.00042
  end

  test "an error the provider sends inside the stream ends it as a failure, with what arrived" do
    error = %{"error" => %{"message" => "upstream died", "code" => 502}}
    events = stream(lm(sse([@content, @usage, error], false)))

    assert [%StreamResponse{chunk: "pong"}, %StreamResponse{done: true} = last] = events
    assert {:error, %Imp.LMError{retryable: true} = reason} = last.chunk
    assert reason.message =~ "upstream died"
    assert %{input_tokens: 7} = last.metadata.usage
    assert last.metadata.usage["cost"] == 0.00042
    refute Enum.any?(events, &match?(%StreamResponse{done: true, chunk: nil}, &1))
  end

  defmodule FinishStub do
    def stream_text(model, messages, opts) do
      finish_reason = Keyword.fetch!(opts, :finish_reason)

      stream =
        Stream.resource(
          fn ->
            [
              ReqLLM.StreamChunk.text("partial"),
              ReqLLM.StreamChunk.meta(%{finish_reason: finish_reason})
            ]
          end,
          fn
            [] -> {:halt, []}
            [chunk | rest] -> {[chunk], rest}
          end,
          fn _state -> :ok end
        )

      {:ok,
       %ReqLLM.StreamResponse{
         stream: stream,
         metadata_handle: self(),
         cancel: fn -> :ok end,
         model: model,
         context: ReqLLM.Context.new(messages)
       }}
    end
  end

  test "a stream that finishes cancelled or in error is not a completion" do
    for finish_reason <- [:cancelled, :error] do
      events =
        %{provider: :openai, id: "local-model", model: "local-model"}
        |> Imp.req_llm(req_module: FinishStub, finish_reason: finish_reason, cache: false)
        |> stream()

      assert [
               %StreamResponse{chunk: "partial"},
               %StreamResponse{
                 chunk: {:error, %Imp.LMError{reason: {:stream_finished, ^finish_reason}}},
                 done: true,
                 metadata: %{finish_reason: ^finish_reason}
               }
             ] = events
    end
  end

  defmodule Collecting do
    @behaviour Imp.Module
    defstruct [:program]

    @impl true
    def call(%__MODULE__{program: program}, inputs),
      do: Imp.collect(program, inputs, provider_stream: true)
  end

  test "a streamed call records the usage and cost the provider reported at the end" do
    answer = "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]"
    content = put_in(@content, ["choices", Access.at(0), "delta", "content"], answer)
    program = Imp.predict("question -> answer", lm: lm(sse([content, @finish, @usage])))

    {:ok, run} = Imp.Run.start(%Collecting{program: program}, %{question: "Capital of France?"})
    assert {:ok, prediction} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)

    assert Imp.get(prediction, :answer) == "Paris"
    assert [response] = Enum.filter(events, &(&1.kind == :model_response))
    assert %{input_tokens: 7, output_tokens: 1, total_tokens: 8} = response.metadata.usage
    assert response.metadata.usage["cost"] == 0.00042
  end
end
