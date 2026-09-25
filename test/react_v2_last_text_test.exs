defmodule ReActV2LastTextTest do
  use ExUnit.Case, async: true

  # A signature with one text output ends every interrupted turn (the step
  # limit, a failed request) with one more request with the same tools and
  # `tool_choice: "auto"` as every step. Its text is the single text output; a
  # tool call in it is not run; what it does not say is an empty answer, not an
  # error. A deadline that has already passed leaves no time for that request.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> %{"seen" => true} end)

  # Answers the first `steps` requests with a tool call and every later one
  # with `last`.
  defp recording_lm(owner, last, steps \\ 1) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if n <= steps do
          %{
            next_thought: "look first",
            tool_calls: [%{id: "c#{n}", name: "look", arguments: %{}}]
          }
        else
          last
        end
      end
    )
  end

  defp requests(n), do: for(i <- 1..n, do: receive(do: ({:request, ^i, m, o} -> {m, o})))

  defp user_contents(messages),
    do: messages |> Enum.filter(&(&1[:role] == :user)) |> Enum.map(& &1[:content])

  test "the step limit spends one more request and takes its text as the answer" do
    owner = self()
    prose = "Two looks were enough: the thing is there."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, prose, 2),
        max_iters: 2
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == prose
    assert prediction.metadata[:termination_reason] == :last_text
    assert prediction.metadata[:termination_cause] == :max_iters

    [{_first, first_opts}, {_second, _}, {last, last_opts}] = requests(3)
    refute_received {:request, 4, _messages, _opts}

    assert Keyword.fetch!(first_opts, :tool_choice) == "auto"
    assert last_opts[:tool_choice] == "auto"
    # The roster is the one every step sent, so the prompt prefix is unchanged.
    assert last_opts[:tools] == first_opts[:tools]

    # Nothing was said on the model's behalf: the last request is the second
    # request plus that step's exchange.
    refute Enum.any?(user_contents(last), &(&1 =~ "step"))

    # The prose is this turn's history event, as an answered step's is.
    messages = prediction.metadata[:history] |> Imp.History.messages()
    assert Enum.any?(messages, &(Map.get(&1, :next_thought) == prose))
  end

  test "the note is the last user message of that request and reaches the history" do
    owner = self()
    note = "You have used every step. Answer now, in your own words."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, "The thing is there."),
        max_iters: 1,
        last_request_note: note
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "The thing is there."

    [_first, {last, _}] = requests(2)
    assert List.last(user_contents(last)) =~ note

    history = prediction.metadata[:history]
    assert Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == note))
  end

  test "no note leaves the last request carrying only the run so far" do
    owner = self()

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, "The thing is there."),
        max_iters: 1
      )

    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {last, _}] = requests(2)

    # Only the first step's exchange separates the two requests: assistant tool
    # call and tool result.
    assert length(last) == length(first) + 2
  end

  test "a last request that says nothing is an empty answer, not an error" do
    owner = self()

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, ""),
        max_iters: 1
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == nil
    assert prediction.metadata[:termination_reason] == :last_text
    refute prediction.metadata[:termination_error]
  end

  test "the last request and its completion are recorded as events" do
    owner = self()
    prose = "The thing is there."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, prose),
        max_iters: 1
      )

    assert {:ok, run} =
             Imp.start_run(program, %{intent: "hello"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, prediction} = Task.await(run.task)
    assert Imp.get(prediction, :answer) == prose
    :ok = Imp.Run.stop(run)

    kinds = run_event_kinds([])
    assert Enum.count(kinds, &(&1 == :model_request)) == 2
    assert Enum.count(kinds, &(&1 == :model_response)) == 2
    assert List.last(kinds) == :run_finished
  end

  defp run_event_kinds(kinds) do
    receive do
      {:run_event, event} -> run_event_kinds([event.kind | kinds])
    after
      0 -> Enum.reverse(kinds)
    end
  end

  test "a failed step takes the same last request, and the cause is recorded" do
    owner = self()
    counter = :counters.new(1, [])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          n = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, n)
          send(owner, {:request, n, messages, opts})

          if n == 1,
            do: raise(RuntimeError, "provider unavailable"),
            else: "I could not look, so from memory: it is there."
        end
      )

    program = Imp.react_v2("intent -> answer", [look()], lm: lm, last_request_note: "Last one.")

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "I could not look, so from memory: it is there."
    assert prediction.metadata[:termination_reason] == :last_text
    assert prediction.metadata[:termination_cause] == :prediction_error

    [_failed, {last, last_opts}] = requests(2)
    assert last_opts[:tool_choice] == "auto"

    # The inputs no step spent come first, and the note is the last thing said.
    [inputs, note] = Enum.take(user_contents(last), -2)
    assert inputs =~ "hello"
    assert note =~ "Last one."
  end

  test "a failed last request records both failures under :initial and :last_text" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> raise(RuntimeError, "provider unavailable") end
      )

    program = Imp.react_v2("intent -> answer", [look()], lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert prediction.metadata[:termination_cause] == :prediction_error
    assert %{initial: _first, last_text: _last} = error = prediction.metadata[:termination_error]
    assert Map.keys(error) |> Enum.sort() == [:initial, :last_text]
  end

  test "a step that calls nothing and says nothing is an empty answer, with no further request" do
    owner = self()
    counter = :counters.new(1, [])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          n = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, n)
          send(owner, {:request, n, messages, opts})
          if n == 1, do: %{tool_calls: []}, else: "Said at last."
        end
      )

    program = Imp.react_v2("intent -> answer", [look()], lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == nil
    assert prediction.metadata[:termination_reason] == :answered
    assert [{_only, _opts}] = requests(1)
    refute_received {:request, 2, _, _}
  end

  # OpenRouter relays an upstream provider's refusal as a successful response
  # whose body is an error object: ReqLLM decodes it to an empty message with
  # the error in `provider_meta`. The last request answers in prose.
  defmodule RelayedErrorReqLLM do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :owner), {:tool_choice, opts[:tool_choice]})

      # The first request is the step; the relayed error makes the next the last.
      {message, meta} =
        if Process.get(:relayed_error_sent),
          do: {"Answered after all.", %{}},
          else:
            (
              Process.put(:relayed_error_sent, true)
              {"", %{"error" => %{"code" => 400, "message" => "Upstream error"}}}
            )

      {:ok,
       %ReqLLM.Response{
         id: "unknown",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant(message),
         provider_meta: meta
       }}
    end
  end

  test "a request the provider refused in its response body is a failed step, not an empty answer" do
    lm =
      Imp.req_llm("openrouter:test/model", req_module: RelayedErrorReqLLM, owner: self())

    program = Imp.react_v2("intent -> answer", [look()], lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "Answered after all."
    assert prediction.metadata[:termination_reason] == :last_text
    assert prediction.metadata[:termination_cause] == :prediction_error
    assert_received {:tool_choice, "auto"}
    assert_received {:tool_choice, "auto"}
  end

  test "a deadline that has already passed makes no last request" do
    owner = self()

    # The deadline passes during the first step's tool call.
    slow_look =
      Imp.tool(:look, "Look at a thing", fn _arguments ->
        Process.sleep(20)
        %{"seen" => true}
      end)

    program =
      Imp.react_v2("intent -> answer", [slow_look],
        lm: recording_lm(owner, "never asked"),
        max_iters: 1,
        last_request_note: "Last one."
      )

    assert {:ok, prediction} =
             Imp.Deadline.with_deadline(10, fn -> Imp.call(program, %{intent: "hello"}) end)

    # The turn was interrupted at the step limit, and what left it without an
    # answer is the deadline.
    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :deadline_exceeded
    assert prediction.fields == %{}
    refute Imp.Prediction.complete?(prediction)

    [_first] = requests(1)
    refute_received {:request, 2, _messages, _opts}

    # The note is what the model would have been told; no request, no note.
    history = prediction.metadata[:history]
    refute Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == "Last one."))
  end

  # A call the model makes on the last request is not run and is not replayed
  # as a call with no result; its text is the answer and the call is named in
  # `unexecuted_tool_calls`.
  test "a tool call on the last request is not run, and its text is the answer" do
    owner = self()

    look =
      Imp.tool(:look, "Look at a thing", fn _arguments ->
        send(owner, :looked)
        %{"seen" => true}
      end)

    last = %{
      next_thought: "One more look, then: it is there.",
      tool_calls: [%{id: "late", name: "look", arguments: %{"where" => "shelf"}}]
    }

    lm = recording_lm(owner, last)

    program = Imp.react_v2("intent -> answer", [look], lm: lm, max_iters: 1)
    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})

    assert_received :looked
    refute_received :looked

    assert Imp.get(prediction, :answer) == "One more look, then: it is there."
    assert prediction.metadata[:termination_reason] == :last_text

    assert [%{id: "late", name: "look", arguments: %{where: "shelf"}}] =
             prediction.metadata[:unexecuted_tool_calls]

    [_first, last] = Imp.History.messages(prediction.metadata[:history])
    assert last.answer == "One more look, then: it is there."
    assert last.tool_calls.tool_calls == []
  end

  # The live failure: the first request failed upstream, and the last request
  # said `tool_choice: "none"` to a model that had done nothing yet and wanted
  # a tool. It wrote the call as text in its own markup, and that text became
  # the answer. The last request offers tools the way every step does, so the
  # model calls the tool natively; the call is not run, and the answer is the
  # completion's text, here none.
  test "after a failed first request, a tool call on the last request is not run and the answer is empty" do
    owner = self()
    counter = :counters.new(1, [])

    identity_status =
      Imp.tool(:identity_status, "Who am I", fn _arguments ->
        send(owner, :identity_status_ran)
        %{"handle" => "gregory"}
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          n = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, n)
          send(owner, {:tool_choice, n, opts[:tool_choice]})

          if n == 1,
            do: raise(RuntimeError, "Service unavailable"),
            else: %{tool_calls: [%{id: "wanted", name: "identity_status", arguments: %{}}]}
        end
      )

    program = Imp.react_v2("intent -> answer", [identity_status], lm: lm)
    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})

    assert_received {:tool_choice, 2, "auto"}
    refute_received :identity_status_ran
    assert Imp.get(prediction, :answer) == nil
    assert prediction.metadata[:termination_reason] == :last_text
    assert prediction.metadata[:termination_cause] == :prediction_error

    assert [%{id: "wanted", name: "identity_status"}] =
             prediction.metadata[:unexecuted_tool_calls]
  end

  # `tool_choice: "none"` makes some models write the call they wanted as text
  # in their own tool markup, which would then be the answer. No request an
  # interrupted turn makes says "none".
  test "no request of an interrupted turn says tool_choice none" do
    owner = self()

    for {lm, max_iters} <- [
          {recording_lm(owner, "Done.", 3), 3},
          {Imp.LM.Static.new(
             handler: fn _messages, opts ->
               send(owner, {:request, :any, [], opts})
               if opts[:tool_choice] == "none", do: "none was sent", else: raise("unavailable")
             end
           ), 5}
        ] do
      program = Imp.react_v2("intent -> answer", [look()], lm: lm, max_iters: max_iters)
      assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
      refute Imp.get(prediction, :answer) == "none was sent"
    end

    choices = collect_choices([])
    assert choices != []
    refute "none" in choices
  end

  defp collect_choices(acc) do
    receive do
      {:request, _n, _messages, opts} -> collect_choices([opts[:tool_choice] | acc])
    after
      0 -> acc
    end
  end

  test "dump and load round-trip the note, and a loaded program has no submit" do
    runner = fn _arguments -> %{"seen" => true} end
    registry = Imp.Saving.Registry.new(look_runner: runner)
    tool = Imp.tool(:look, "Look at a thing", runner)

    dumped =
      Imp.react_v2("intent -> answer", [tool], last_request_note: "Answer now.")
      |> Imp.dump(registry: registry)

    assert dumped["last_request_note"] == "Answer now."
    refute Map.has_key?(dumped, "on_max_iters")

    loaded = Imp.load(dumped, registry: registry)
    assert loaded.last_request_note == "Answer now."
    refute Map.has_key?(loaded.tools, :submit)

    with_submit =
      Imp.react_v2("intent -> answer, confidence: float", [tool])
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)

    assert Map.has_key?(with_submit.tools, :submit)
  end
end
