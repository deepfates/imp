defmodule Imp.StoppedCompletionTest do
  # A completion the provider answered with HTTP 200 but stopped, by its
  # content filter or with finish reason "error", is a failed request. The
  # provider billed it all the same, so its usage and cost are recorded, and a
  # ReAct turn does not pay for the filtered request twice.
  use ExUnit.Case, async: false

  defp completion(finish_reason, content) do
    %{
      "id" => "gen-stopped",
      "object" => "chat.completion",
      "model" => "test/model",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => finish_reason,
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{
        "prompt_tokens" => 10,
        "completion_tokens" => 3,
        "total_tokens" => 13,
        "cost" => 0.0025
      }
    }
  end

  # An OpenRouter client against a local server that answers every request
  # with `body` and tells the test about each request it receives.
  defp lm(body) do
    owner = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        send(owner, :provider_request)
        {200, body}
      end)

    Imp.req_llm("openrouter:test/model",
      base_url: base_url <> "/v1",
      api_key: "local-test-key",
      cache: false
    )
  end

  defmodule CallsLM do
    @behaviour Imp.Module
    defstruct [:lm, :owner, :signature]

    @impl true
    def call(%__MODULE__{lm: lm, owner: owner}, _inputs) do
      {result, usage} =
        Imp.Usage.track(fn -> Imp.LM.generate(lm, [%{role: :user, content: "ping"}]) end)

      send(owner, {:tracked_usage, usage})
      result
    end
  end

  @filter_text "The request was rejected because it was considered high risk"

  test "a filtered completion records the usage and cost the provider billed" do
    lm = lm(completion("content_filter", @filter_text))

    {:ok, run} = Imp.Run.start(%CallsLM{lm: lm, owner: self()}, %{question: "q"})
    assert {:error, %Imp.LMError{content_filtered: true, retryable: false}} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)

    # The event a host reads for spend: the failed call's `:model_response`.
    assert %Imp.Run.Event{
             error: %Imp.LMError{content_filtered: true},
             metadata: %{
               cost: 0.0025,
               usage: %{"cost" => 0.0025, input_tokens: 10, output_tokens: 3}
             }
           } = Enum.find(events, &(&1.kind == :model_response))

    assert_received {:tracked_usage, %{"openrouter/test/model" => usage}}
    assert usage["cost"] == 0.0025
    assert usage[:input_tokens] == 10
  end

  test "a ReAct step the content filter stopped fails the turn with no further request" do
    lm = lm(completion("content_filter", @filter_text))
    look = Imp.tool(:look, "Look at a thing", fn _arguments -> %{"seen" => true} end)
    program = Imp.react("intent -> answer", [look], lm: lm)

    assert {:error, %Imp.Predict.ReActV2.StepError{reason: %Imp.LMError{content_filtered: true}}} =
             Imp.call(program, %{intent: "hello"})

    assert_received :provider_request
    refute_received :provider_request
  end

  test "a completion that finished with reason error is a failed request carrying its text" do
    lm = lm(completion("error", "provider text"))

    assert {:error, %Imp.LMError{retryable: false, content_filtered: false} = error} =
             Imp.LM.generate(lm, [%{role: :user, content: "ping"}])

    assert error.message =~ "provider text"
  end
end
