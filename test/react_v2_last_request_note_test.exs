defmodule ReActV2LastRequestNoteTest do
  use ExUnit.Case, async: true

  # The forced submit belongs to a signature with `submit`: more than one
  # output, or one that is not text.
  @signature "intent -> answer, confidence: float"

  # The last request of an interrupted turn says nothing about why it is being
  # made. A host that wants the model told sets `:last_request_note`, one
  # option for both kinds of signature; the note is a user message in that
  # request and stays in the returned history, because the record of the run
  # has to contain what the model was told. `react_v2_last_text_test.exs`
  # covers the signature with one text output.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => true} end)

  defp recording_lm(owner) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if forced?(opts) do
          %{tool_calls: [%{id: "s", name: "submit", arguments: %{answer: "ok", confidence: 1.0}}]}
        else
          %{
            next_thought: "look first",
            tool_calls: [%{id: "c", name: "look", arguments: %{}}]
          }
        end
      end
    )
  end

  defp forced?(opts), do: opts[:tool_choice] not in [nil, "auto"]

  defp requests(n), do: for(i <- 1..n, do: receive(do: ({:request, ^i, m, o} -> {m, o})))

  defp user_contents(messages),
    do: messages |> Enum.filter(&(&1[:role] == :user)) |> Enum.map(& &1[:content])

  test "the note is the last user message of the forced request and reaches the history" do
    owner = self()
    note = "You have used every turn. Submit the answer you have now."

    program =
      Imp.react(@signature, [look()],
        lm: recording_lm(owner),
        max_iters: 1,
        last_request_note: note
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"
    # The forced submit answered, and the turn still says what interrupted it.
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :max_iters

    [{_first, _}, {forced, forced_opts}] = requests(2)
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}
    assert List.last(user_contents(forced)) =~ note

    history = prediction.metadata.history
    assert Enum.any?(Imp.History.messages(history), &(Map.get(&1, :intent) == note))

    # omit_empty_request: the forced request carries no new pending inputs, so
    # there is no blank user message after the note turn.
    refute Enum.any?(forced, &(&1[:role] == :user and String.trim(&1[:content] || "") == ""))
  end

  # An LM that writes its tool calls as text: the step lists the tools and
  # replays earlier steps as text, never as native tool messages.
  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  @filler "Not supplied for this conversation history message."

  # The first request looks; every later one submits. The replies are native
  # tool calls, or the same calls written as text for an LM that cannot call
  # tools.
  defp moded_lm(owner, native?) do
    counter = :counters.new(1, [])

    handler = fn messages, opts ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(owner, {:request, n, messages, opts})
      step_reply(native?, if(n == 1, do: :look, else: :submit))
    end

    if native?, do: Imp.LM.Static.new(handler: handler), else: %TextOnlyLM{handler: handler}
  end

  defp step_reply(true, :look),
    do: %{next_thought: "look first", tool_calls: [%{id: "c", name: "look", arguments: %{}}]}

  defp step_reply(true, :submit),
    do: %{tool_calls: [%{id: "s", name: "submit", arguments: %{answer: "ok", confidence: 1.0}}]}

  defp step_reply(false, :look),
    do:
      ~s([[ ## next_thought ## ]]\nlook first\n\n[[ ## tool_calls ## ]]\n[{"name": "look", "arguments": {}}])

  defp step_reply(false, :submit),
    do:
      ~s([[ ## next_thought ## ]]\nsubmitting\n\n[[ ## tool_calls ## ]]\n[{"name": "submit", "arguments": {"answer": "ok", "confidence": 1.0}}])

  defp note_index(messages, note),
    do: Enum.find_index(messages, &(&1.role == :user and to_string(&1.content) =~ note))

  for {mode, native?} <- [native: true, prompt: false] do
    @native native?

    test "#{mode} tools: the note ends the forced request as a user message, with no invented reply" do
      owner = self()
      note = "You have used every turn. Submit the answer you have now."

      program =
        Imp.react(@signature, [look()],
          lm: moded_lm(owner, @native),
          max_iters: 1,
          last_request_note: note
        )

      assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
      assert prediction.metadata.termination_reason == :forced_submit

      [_first, {forced, _opts}] = requests(2)
      refute Enum.any?(forced, &(to_string(&1.content) =~ @filler))

      index = note_index(forced, note)
      assert index
      after_note = Enum.drop(forced, index + 1)

      # Natively the note is the last message. A step that lists its tools as
      # text ends every request on that listing, a user message too.
      if @native,
        do: assert(after_note == []),
        else:
          assert([%{role: :user, content: listing}] = after_note) && assert(listing =~ "tools")
    end

    test "#{mode} tools: a returned history replays the note as the user turn the model answered" do
      owner = self()
      note = "You have used every turn. Submit the answer you have now."

      program =
        Imp.react(@signature, [look()],
          lm: moded_lm(owner, @native),
          max_iters: 1,
          last_request_note: note
        )

      assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
      _ = requests(2)

      # A host keeps the history as data and hands it back on the next turn.
      history = prediction.metadata.history |> Imp.History.dump() |> Imp.History.load!()
      assert {:ok, _prediction} = Imp.call(program, %{intent: "again", history: history})

      {replayed, _opts} = receive(do: ({:request, 3, m, o} -> {m, o}))
      refute Enum.any?(replayed, &(to_string(&1.content) =~ @filler))

      # What follows the note is the reply the model actually gave: the submit.
      index = note_index(replayed, note)
      assert index
      reply = Enum.at(replayed, index + 1)
      assert reply.role == :assistant

      if @native,
        do: assert(Enum.map(reply.tool_calls, & &1.function.name) == ["submit"]),
        else: assert(reply.content =~ "submit")
    end
  end

  # A `History` entry a host wrote with inputs and no outputs has no reply to
  # show, so it is its user message alone, like a turn the loop recorded
  # without one. DSPy 3.2.1 renders the missing outputs as `None`.
  test "a host's input-only history entry is its user message alone" do
    owner = self()
    program = Imp.react(@signature, [look()], lm: moded_lm(owner, true), max_iters: 1)
    history = Imp.History.new([%{intent: "earlier"}])

    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello", history: history})
    [{first, _opts}, _forced] = requests(2)

    index = note_index(first, "earlier")
    assert %{role: :user} = Enum.at(first, index + 1)
    refute Enum.any?(first, &(&1.role == :assistant and to_string(&1.content) =~ @filler))
  end

  test "no note leaves the forced request exactly as it was" do
    owner = self()

    program =
      Imp.react(@signature, [look()], lm: recording_lm(owner), max_iters: 1)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {forced, _}] = requests(2)

    # Only the first step's exchange separates the two requests: user inputs,
    # assistant tool call, tool result. Nothing was added on the model's behalf.
    assert length(forced) == length(first) + 2
    assert Enum.count(Imp.History.messages(prediction.metadata.history)) == 2
  end

  test "the note is saved with the program, whichever kind of signature it has" do
    for signature <- [@signature, "intent -> answer"] do
      program = Imp.react(signature, [], last_request_note: "Answer now.")
      dumped = Imp.dump(program)
      assert dumped["last_request_note"] == "Answer now."
      assert Imp.load!(dumped).last_request_note == "Answer now."
    end
  end

  # A host holding a conversation asks one more thing of it: the conversation's
  # own messages, the loop's tools, then the note. One request, and no tool runs.
  test "a call's own note with max_iters 0 continues a history with one request" do
    owner = self()
    ran = :counters.new(1, [])
    look = Imp.tool(:look, "Look at a thing", fn _ -> :counters.add(ran, 1, 1) && "seen" end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:request, messages, opts})
          # Asked to summarise, the model reaches for a tool anyway, and says so.
          %{
            answer: "I looked at the box.",
            tool_calls: [%{id: "x", name: "look", arguments: %{}}]
          }
        end
      )

    program = Imp.react("intent -> answer", [look], lm: lm, last_request_note: "Last action.")

    history =
      Imp.History.new([
        %{
          intent: "what is in the box?",
          next_thought: "",
          tool_calls: %{tool_calls: [%{id: "c", name: "look", arguments: %{}}]},
          tool_call_results: [%{id: "c", name: "look", result: "a cat"}]
        }
      ])

    note = "Summarise this conversation."

    assert {:ok, prediction} =
             Imp.call(program, %{history: history, max_iters: 0, last_request_note: note})

    assert Imp.get(prediction, :answer) == "I looked at the box."
    assert prediction.metadata.termination_reason == :last_text
    assert [%{name: "look"}] = prediction.metadata.unexecuted_tool_calls
    assert :counters.get(ran, 1) == 0

    assert_received {:request, messages, opts}
    refute_received {:request, _, _}

    # The loop's own tools, offered as on every step.
    assert opts[:tool_choice] == "auto"
    assert [_look] = opts[:tools]

    # The conversation as the model saw it, the call's note last, and not the
    # program's own.
    assert [:system, :user, :assistant, :tool, :user] == Enum.map(messages, & &1.role)
    assert Enum.at(messages, 3).content =~ "a cat"
    assert List.last(messages).content =~ note
    refute Enum.any?(messages, &(to_string(&1.content) =~ "Last action."))
  end

  test "a call's note is a string or nil, refused before the model is called" do
    owner = self()
    program = Imp.react("intent -> answer", [look()], lm: recording_lm(owner))

    for bad <- [7, %{text: "no"}] do
      for key <- [:last_request_note, "last_request_note"] do
        assert {:error, {:invalid_react_v2_last_request_note, ^bad}} =
                 Imp.call(program, %{key => bad, intent: "hello"})
      end
    end

    refute_received {:request, _, _, _}
  end

  test "the option takes a string or nil and nothing else" do
    for bad <- [fn _reason -> "no" end, 7] do
      assert_raise ArgumentError, ~r/last_request_note/, fn ->
        Imp.react(@signature, [look()], last_request_note: bad)
      end
    end

    for gone <- [:forced_submit_notice, :last_text_note] do
      assert_raise ArgumentError, ~r/unknown options/, fn ->
        Imp.react(@signature, [look()], [{gone, "Submit now."}])
      end
    end
  end
end
