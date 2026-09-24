defmodule ReActV2LastProseTest do
  use ExUnit.Case, async: true

  # A signature with one text output ends every interrupted turn (the step
  # limit, a failed request, a step that calls nothing and says nothing) with
  # one request with `tool_choice: "none"` and the same tools as every step, so
  # the model can only write text. What it writes is the single text output; what it does not say
  # is an empty answer, not an error. A deadline that has already passed
  # leaves no time for that request.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> %{"seen" => true} end)

  defp recording_lm(owner, last) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if opts[:tool_choice] != "none" do
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

  test "the step limit spends one request that allows no tool call and takes its prose as the answer" do
    owner = self()
    prose = "Two looks were enough: the thing is there."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, prose),
        max_iters: 2
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == prose
    assert Imp.get(prediction, :termination_reason) == :last_prose
    assert Imp.get(prediction, :termination_cause) == :max_iters

    [{_first, first_opts}, {_second, _}, {last, last_opts}] = requests(3)
    refute_received {:request, 4, _messages, _opts}

    assert Keyword.fetch!(first_opts, :tool_choice) == "auto"
    assert last_opts[:tool_choice] == "none"
    # The roster is the one every step sent, so the prompt prefix is unchanged.
    assert last_opts[:tools] == first_opts[:tools]

    # Nothing was said on the model's behalf: the last request is the second
    # request plus that step's exchange.
    refute Enum.any?(user_contents(last), &(&1 =~ "step"))

    # The prose is this turn's history event, as an answered step's is.
    messages = prediction |> Imp.get(:history) |> Imp.History.messages()
    assert Enum.any?(messages, &(Map.get(&1, :next_thought) == prose))
  end

  test "the note is the last user message of that request and reaches the history" do
    owner = self()
    note = "You have used every step. Answer now, in your own words."

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(owner, "The thing is there."),
        max_iters: 1,
        last_prose_note: note
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "The thing is there."

    [_first, {last, _}] = requests(2)
    assert List.last(user_contents(last)) =~ note

    history = Imp.get(prediction, :history)
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
    assert Imp.get(prediction, :termination_reason) == :last_prose
    refute Imp.get(prediction, :termination_error)
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
    assert Enum.count(kinds, &(&1 == :final)) == 1
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

    program = Imp.react_v2("intent -> answer", [look()], lm: lm, last_prose_note: "Last one.")

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "I could not look, so from memory: it is there."
    assert Imp.get(prediction, :termination_reason) == :last_prose
    assert Imp.get(prediction, :termination_cause) == :prediction_error

    [_failed, {last, last_opts}] = requests(2)
    assert last_opts[:tool_choice] == "none"

    # The inputs no step spent come first, and the note is the last thing said.
    [inputs, note] = Enum.take(user_contents(last), -2)
    assert inputs =~ "hello"
    assert note =~ "Last one."
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
    assert Imp.get(prediction, :termination_reason) == :answered
    assert [{_only, _opts}] = requests(1)
    refute_received {:request, 2, _, _}
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
        last_prose_note: "Last one."
      )

    assert {:ok, prediction} =
             Imp.Deadline.with_deadline(10, fn -> Imp.call(program, %{intent: "hello"}) end)

    assert Imp.get(prediction, :termination_reason) == :deadline_exceeded
    assert Imp.get(prediction, :termination_cause) == :max_iters
    assert Imp.get(prediction, :answer) == nil

    [_first] = requests(1)
    refute_received {:request, 2, _messages, _opts}

    # The note is what the model would have been told; no request, no note.
    history = Imp.get(prediction, :history)
    refute Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == "Last one."))
  end

  # `tool_choice: "none"` is a request, not a guarantee. A call the model makes
  # anyway is not run and is not replayed as a call with no result; its text
  # is the answer and the call is named in `unexecuted_tool_calls`.
  test "a tool call on the last request is not run, and its text is the answer" do
    owner = self()
    counter = :counters.new(1, [])

    look =
      Imp.tool(:look, "Look at a thing", fn _arguments ->
        send(owner, :looked)
        %{"seen" => true}
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          n = :counters.get(counter, 1) + 1
          :counters.put(counter, 1, n)

          if opts[:tool_choice] == "none",
            do: %{
              next_thought: "One more look, then: it is there.",
              tool_calls: [%{id: "late", name: "look", arguments: %{"where" => "shelf"}}]
            },
            else: %{tool_calls: [%{id: "c#{n}", name: "look", arguments: %{}}]}
        end
      )

    program = Imp.react_v2("intent -> answer", [look], lm: lm, max_iters: 1)
    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})

    assert_received :looked
    refute_received :looked

    assert Imp.get(prediction, :answer) == "One more look, then: it is there."
    assert Imp.get(prediction, :termination_reason) == :last_prose

    assert [%{id: "late", name: "look", arguments: %{where: "shelf"}}] =
             Imp.get(prediction, :unexecuted_tool_calls)

    [_first, last] = Imp.History.messages(Imp.get(prediction, :history))
    assert last.answer == "One more look, then: it is there."
    assert last.tool_calls.tool_calls == []
  end

  test "each note is refused for the signature it does not belong to" do
    assert_raise ArgumentError,
                 ~r/:last_prose_note needs a signature with exactly one output/,
                 fn ->
                   Imp.react_v2("intent -> answer, confidence: float", [look()],
                     last_prose_note: "Now."
                   )
                 end

    assert_raise ArgumentError, ~r/:forced_submit_notice needs a signature with submit/, fn ->
      Imp.react_v2("intent -> answer", [look()], forced_submit_notice: "Now.")
    end
  end

  test "dump and load round-trip the note, and a loaded program has no submit" do
    runner = fn _arguments -> %{"seen" => true} end
    registry = Imp.Saving.Registry.new(look_runner: runner)
    tool = Imp.tool(:look, "Look at a thing", runner)

    dumped =
      Imp.react_v2("intent -> answer", [tool], last_prose_note: "Answer now.")
      |> Imp.dump(registry: registry)

    assert dumped["last_prose_note"] == "Answer now."
    refute Map.has_key?(dumped, "on_max_iters")

    loaded = Imp.load(dumped, registry: registry)
    assert loaded.last_prose_note == "Answer now."
    refute Map.has_key?(loaded.tools, :submit)

    with_submit =
      Imp.react_v2("intent -> answer, confidence: float", [tool])
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)

    assert Map.has_key?(with_submit.tools, :submit)
  end
end
