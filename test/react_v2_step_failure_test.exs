defmodule ReActV2StepFailureTest do
  # A turn that could not get a model response returns the failed request's
  # error, never a prediction. A tool call whose outcome is unknown is an
  # observation, not such a failure.
  use ExUnit.Case, async: false

  @submit_signature "question -> answer, confidence: float"
  @look_call %{tool_calls: [%{id: "first", name: "look", arguments: %{"where" => "shelf"}}]}

  defmodule ServerErrorAdapter do
    # A Req adapter that answers every request with a 500, as a provider does
    # when it fails.
    def run(request) do
      send(:react_v2_step_failure_owner, :http_request)

      response =
        Req.Response.new(
          status: 500,
          headers: %{"content-type" => ["application/json"]},
          body: %{"error" => %{"message" => "upstream failed", "type" => "server_error"}}
        )

      {request, response}
    end
  end

  defp look(owner) do
    Imp.tool(:look, "Look at a thing", fn _arguments ->
      send(owner, :looked)
      %{"seen" => true}
    end)
  end

  defp unavailable,
    do: %Imp.LMError{message: "provider unavailable", status: 503, retryable: true}

  # An LM that answers `replies` in order and fails every request after them.
  defp failing_after(replies) do
    owner = self()
    counter = :counters.new(1, [])

    Imp.Test.FunLM.new(fn _messages, _opts ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(owner, {:request, n})

      case Enum.at(replies, n - 1) do
        nil -> {:error, unavailable()}
        reply -> {:ok, reply}
      end
    end)
  end

  defp request_count(n \\ 0) do
    receive do
      {:request, _n} -> request_count(n + 1)
    after
      0 -> n
    end
  end

  describe "an LM that fails on step 1" do
    test "a text answer returns the LM error" do
      program = Imp.react("intent -> answer", [look(self())], lm: failing_after([]))

      assert {:error, %Imp.LMError{status: 503} = error} =
               Imp.call(program, %{intent: "hello"})

      assert Imp.Errors.retryable?(error)
      # The step and its last request.
      assert request_count() == 2
    end

    test "a signature with submit returns the LM error" do
      program = Imp.react(@submit_signature, [look(self())], lm: failing_after([]))

      assert {:error, %Imp.LMError{status: 503}} =
               Imp.call(program, %{question: "Capital of France?"})

      # The step and its forced submit.
      assert request_count() == 2
    end
  end

  describe "an LM that fails on step 2" do
    test "returns the LM error, and the step before it is in the run's events" do
      owner = self()
      program = Imp.react("intent -> answer", [look(owner)], lm: failing_after([@look_call]))

      assert {:ok, run} =
               Imp.start_run(program, %{intent: "hello"},
                 event_sink: fn event -> send(owner, {:run_event, event}) end
               )

      assert {:error, %Imp.LMError{status: 503}} = Task.await(run.task)
      :ok = Imp.Run.stop(run)

      assert_received :looked
      kinds = run_event_kinds([])
      assert :tool_call in kinds
      assert :tool_result in kinds
      assert List.last(kinds) == :run_failed
    end

    test "a signature with submit returns the LM error" do
      program = Imp.react(@submit_signature, [look(self())], lm: failing_after([@look_call]))

      assert {:error, %Imp.LMError{status: 503}} =
               Imp.call(program, %{question: "Capital of France?"})

      assert_received :looked
    end
  end

  test "a system renderer that raises returns the renderer's error" do
    renderer = fn _signature, _opts -> raise ArgumentError, "renderer broke" end

    program =
      Imp.react("intent -> answer", [look(self())],
        lm: failing_after(["never read"]),
        adapter_opts: [system_renderer: renderer]
      )

    assert {:error,
            {:adapter_format_failed, Imp.Adapter.Chat, %ArgumentError{message: "renderer broke"}}} =
             Imp.call(program, %{intent: "hello"})

    # The request is never formatted, so the LM is never called.
    assert request_count() == 0
  end

  test "a ReqLLM client whose provider answers 500 returns the LM error" do
    Process.register(self(), :react_v2_step_failure_owner)

    lm =
      Imp.req_llm("openai:gpt-4o-mini",
        api_key: "fixture",
        cache: false,
        req_http_options: [adapter: ServerErrorAdapter, retry: false, max_retries: 0]
      )

    program = Imp.react("intent -> answer", [look(self())], lm: lm)

    assert {:error, %Imp.LMError{status: 500}} = Imp.call(program, %{intent: "hello"})
    assert_received :http_request
  end

  test "a step that recovers on its last request answers with its text" do
    counter = :counters.new(1, [])

    # Only the first request fails.
    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: {:error, unavailable()},
          else: {:ok, "From memory: it is there."}
      end)

    program = Imp.react("intent -> answer", [look(self())], lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "From memory: it is there."
    assert prediction.metadata[:termination_reason] == :last_text
    assert prediction.metadata[:termination_cause] == :prediction_error
  end

  test "a tool call whose outcome is unknown is an observation, and the turn answers" do
    crashing = Imp.tool(:look, "Look at a thing", fn _arguments -> raise "lost connection" end)

    program =
      Imp.react("intent -> answer", [crashing],
        lm: failing_after([@look_call, "I could not tell whether the look happened."])
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert prediction.metadata[:termination_reason] == :answered
    assert Imp.get(prediction, :answer) == "I could not tell whether the look happened."
  end

  defp run_event_kinds(kinds) do
    receive do
      {:run_event, event} -> run_event_kinds([event.kind | kinds])
    after
      0 -> Enum.reverse(kinds)
    end
  end
end
