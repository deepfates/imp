defmodule ReActV2StepFailureTest do
  # A turn that could not get a model response returns a StepError carrying
  # the failed request's error and the history so far, never a prediction. A
  # tool call whose outcome is unknown is an observation, not such a failure.
  use ExUnit.Case, async: false

  alias Imp.Predict.ReActV2.StepError

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

      assert {:error, %StepError{reason: %Imp.LMError{status: 503}} = error} =
               Imp.call(program, %{intent: "hello"})

      assert Imp.Errors.retryable?(error)
      assert Exception.message(error) =~ "provider unavailable"
      # The step and its last request.
      assert request_count() == 2
    end

    test "a signature with submit returns the LM error" do
      program = Imp.react(@submit_signature, [look(self())], lm: failing_after([]))

      assert {:error, %StepError{reason: %Imp.LMError{status: 503}}} =
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

      assert {:error, %StepError{reason: %Imp.LMError{status: 503}}} = Task.await(run.task)
      :ok = Imp.Run.stop(run)

      assert_received :looked
      kinds = run_event_kinds([])
      assert :tool_call in kinds
      assert :tool_result in kinds
      assert List.last(kinds) == :run_failed
    end

    test "a signature with submit returns the LM error" do
      program = Imp.react(@submit_signature, [look(self())], lm: failing_after([@look_call]))

      assert {:error, %StepError{reason: %Imp.LMError{status: 503}, history: history}} =
               Imp.call(program, %{question: "Capital of France?"})

      assert_received :looked
      assert [%{tool_calls: %{tool_calls: [%{id: "first"}]}}] = history.messages
    end

    # The tool ran, so the history the error carries holds its call and
    # result exactly as the turn's history held them when the model failed:
    # the history of the same turn whose last request answered with nothing,
    # which adds no step.
    test "the error's history holds the tool call and its observation" do
      owner = self()

      assert {:error, %StepError{history: failed}} =
               Imp.react("intent -> answer", [look(owner)], lm: failing_after([@look_call]))
               |> Imp.call(%{intent: "hello"})

      step_two = :counters.new(1, [])

      answered_nothing =
        Imp.Test.FunLM.new(fn _messages, _opts ->
          :counters.add(step_two, 1, 1)

          case :counters.get(step_two, 1) do
            1 -> {:ok, @look_call}
            2 -> {:error, unavailable()}
            _last -> {:ok, ""}
          end
        end)

      assert {:ok, prediction} =
               Imp.react("intent -> answer", [look(owner)], lm: answered_nothing)
               |> Imp.call(%{intent: "hello"})

      assert prediction.metadata[:termination_reason] == :last_text
      assert failed == prediction.metadata[:history]

      assert [%{intent: "hello", tool_calls: calls, tool_call_results: [result]}] =
               failed.messages

      assert [%{id: "first", name: "look", arguments: %{"where" => "shelf"}}] = calls.tool_calls
      assert %{id: "first", name: "look", result: %{"seen" => true}, error: false} = result
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
            %StepError{
              reason:
                {:adapter_format_failed, Imp.Adapter.Chat,
                 %ArgumentError{message: "renderer broke"}}
            } = error} = Imp.call(program, %{intent: "hello"})

    assert Exception.message(error) =~ "renderer broke"

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

    assert {:error, %StepError{reason: %Imp.LMError{status: 500}}} =
             Imp.call(program, %{intent: "hello"})

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

  describe "a step that an operational safety guard refuses" do
    # The guard fires on step 2, after a tool ran; the LM would answer a last
    # request, which must not be made.
    defp guarded(safety) do
      owner = self()
      counter = :counters.new(1, [])

      Imp.Test.FunLM.new(fn _messages, _opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(owner, {:request, n})

        case n do
          1 -> {:ok, @look_call}
          2 -> {:error, safety}
          _last -> {:ok, "Answered after the guard."}
        end
      end)
    end

    for {kind, signature, inputs} <- [
          {:route, "intent -> answer", %{intent: "hello"}},
          {:budget, "question -> answer, confidence: float", %{question: "Capital of France?"}}
        ] do
      test "#{kind}: ends the turn at once with the guard's error" do
        safety =
          Imp.OperationalSafetyError.exception(
            kind: unquote(kind),
            reason: :refused_by_fixture
          )

        program = Imp.react(unquote(signature), [look(self())], lm: guarded(safety))

        assert {:error, %StepError{reason: ^safety, history: history} = error} =
                 Imp.call(program, unquote(Macro.escape(inputs)))

        # The step that ran and the refused one; no last request.
        assert request_count() == 2
        assert Imp.OperationalSafetyError.find(error) == safety

        assert_raise Imp.OperationalSafetyError, fn ->
          Imp.OperationalSafetyError.raise_if_present!({:error, error})
        end

        assert [%{tool_calls: %{tool_calls: [%{id: "first"}]}}] = history.messages
      end
    end

    test "a guard raised inside the LM client is fatal too" do
      safety = Imp.OperationalSafetyError.exception(kind: :budget, reason: :spent)
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)
            if :counters.get(counter, 1) == 1, do: raise(safety), else: "Answered anyway."
          end
        )

      assert {:error, %StepError{reason: ^safety}} =
               Imp.react("intent -> answer", [look(self())], lm: lm)
               |> Imp.call(%{intent: "hello"})

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "a guard's refusal a tool returned" do
    # The tool's result is an observation the turn goes on from; only the
    # request that stopped the turn says why it stopped.
    defp charge_program(after_charge) do
      cost = Imp.OperationalSafetyError.exception(kind: :cost, reason: :over_cap)
      charge = Imp.tool(:charge, "Charge the card", fn _arguments -> {:error, cost} end)
      counter = :counters.new(1, [])

      lm =
        Imp.Test.FunLM.new(fn _messages, _opts ->
          :counters.add(counter, 1, 1)

          case :counters.get(counter, 1) do
            1 -> {:ok, %{tool_calls: [%{id: "charge", name: "charge", arguments: %{}}]}}
            _later -> after_charge
          end
        end)

      Imp.react("intent -> answer", [charge], lm: lm)
    end

    defp devset, do: [Imp.example(intent: "pay", answer: "Paid.") |> Imp.with_inputs(:intent)]
    defp metric, do: fn _example, _prediction, _trace -> 1.0 end

    test "a turn that answers after it is scored" do
      result = Imp.evaluate(charge_program({:ok, "Could not pay."}), devset(), metric())

      assert result.errors == []
      assert result.score > 0
    end

    test "a turn whose model then fails is an error row, not the guard" do
      program = charge_program({:error, unavailable()})

      assert {:error, %StepError{reason: %Imp.LMError{status: 503}, history: history} = error} =
               Imp.call(program, %{intent: "pay"})

      assert inspect(history) =~ "over_cap"
      assert Imp.OperationalSafetyError.find(error) == nil

      result = Imp.evaluate(program, devset(), metric())
      assert [%{reason: %StepError{reason: %Imp.LMError{status: 503}}}] = result.errors
    end
  end

  # An endpoint that cannot name `submit` in `tool_choice` gets the forced
  # submit again with "required"; a guard refusing that request ends the turn,
  # rather than the typed extraction answering past it.
  test "a guard refusing the required-only forced submit is fatal" do
    safety = Imp.OperationalSafetyError.exception(kind: :route, reason: :refused_by_fixture)
    owner = self()
    counter = :counters.new(1, [])

    unsupported = %Imp.LMError{
      status: 400,
      message: "Invalid value for 'tool_choice': supported string values are none, auto, required"
    }

    lm =
      Imp.Test.FunLM.new(fn _messages, opts ->
        :counters.add(counter, 1, 1)
        send(owner, {:tool_choice, opts[:tool_choice]})

        case :counters.get(counter, 1) do
          1 -> {:ok, "Prose, no call."}
          2 -> {:error, unsupported}
          3 -> {:error, safety}
          _extraction -> {:ok, %{reasoning: "From memory.", answer: "Paris", confidence: 0.5}}
        end
      end)

    assert {:error, %StepError{reason: ^safety}} =
             Imp.react(@submit_signature, [look(self())], lm: lm)
             |> Imp.call(%{question: "Capital of France?"})

    assert_received {:tool_choice, %{type: "tool", name: "submit"}}
    assert_received {:tool_choice, "required"}
    assert :counters.get(counter, 1) == 3
  end

  test "inspecting the error shows the reason and the history's size, not the history" do
    owner = self()

    assert {:error, %StepError{history: history} = error} =
             Imp.react("intent -> answer", [look(owner)], lm: failing_after([@look_call]))
             |> Imp.call(%{intent: "a secret intent"})

    assert length(history.messages) == 1
    text = inspect(error)

    assert text =~ "#Imp.Predict.ReActV2.StepError<reason: %Imp.LMError{"
    assert text =~ "status: 503"
    assert text =~ "history: 1 message>"
    refute text =~ "a secret intent"
    refute text =~ "seen"
  end

  # A last request refused because the context window is full ends the turn
  # incomplete, not as an error: the caller shortens the input.
  test "a last request refused for length is incomplete, not an error" do
    counter = :counters.new(1, [])

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: {:error, unavailable()},
          else: {:error, %Imp.LMError{status: 400, context_window_exceeded: true}}
      end)

    assert {:ok, prediction} =
             Imp.react("intent -> answer", [look(self())], lm: lm)
             |> Imp.call(%{intent: "hello"})

    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :context_window_exceeded
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
