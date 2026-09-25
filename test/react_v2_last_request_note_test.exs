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
      Imp.react_v2(@signature, [look()],
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

  test "no note leaves the forced request exactly as it was" do
    owner = self()

    program =
      Imp.react_v2(@signature, [look()], lm: recording_lm(owner), max_iters: 1)

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    [{first, _}, {forced, _}] = requests(2)

    # Only the first step's exchange separates the two requests: user inputs,
    # assistant tool call, tool result. Nothing was added on the model's behalf.
    assert length(forced) == length(first) + 2
    assert Enum.count(Imp.History.messages(prediction.metadata.history)) == 2
  end

  test "the note is saved with the program, whichever kind of signature it has" do
    for signature <- [@signature, "intent -> answer"] do
      program = Imp.react_v2(signature, [], last_request_note: "Answer now.")
      dumped = Imp.dump(program)
      assert dumped["last_request_note"] == "Answer now."
      assert Imp.load(dumped).last_request_note == "Answer now."
    end
  end

  test "the option takes a string or nil and nothing else" do
    for bad <- [fn _reason -> "no" end, 7] do
      assert_raise ArgumentError, ~r/last_request_note/, fn ->
        Imp.react_v2(@signature, [look()], last_request_note: bad)
      end
    end

    for gone <- [:forced_submit_notice, :last_text_note] do
      assert_raise ArgumentError, ~r/unknown options/, fn ->
        Imp.react_v2(@signature, [look()], [{gone, "Submit now."}])
      end
    end
  end
end
