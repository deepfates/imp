defmodule ReActV2EndingSwitchTest do
  use ExUnit.Case, async: true

  # A host can change a program's ending mid-conversation and pass the same
  # history on. A step that answered in plain text (`finish: :auto`) was the
  # answer, not a thought, under either ending; a `submit`-era history
  # replayed in a plain-text loop keeps roles alternating.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)

  @note_start "Your message above was not sent."

  defp scripted(owner, replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        send(owner, {:request, messages})

        Agent.get_and_update(agent, fn
          [reply | rest] -> {reply, rest}
          [] -> {%{tool_calls: []}, []}
        end)
      end
    )
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages} -> requests([messages | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp program(replies, finish),
    do: Imp.react("ticket -> reply", [look()], lm: scripted(self(), replies), finish: finish)

  defp shape(messages), do: Enum.map(tl(messages), &{&1.role, to_string(&1.content)})

  test "plain-text answers replayed under finish: :submit are answers, with no unsent line" do
    {:ok, first} =
      program([%{reply: "It is a cat.", tool_calls: []}], :auto)
      |> Imp.call(%{ticket: "What is in the box?"})

    {:ok, second} =
      program([%{reply: "It is asleep.", tool_calls: []}], :auto)
      |> Imp.call(%{ticket: "Is it awake?", history: first.metadata.history})

    _plain = requests()

    submit = %{tool_calls: [%{id: "s1", name: "submit", arguments: %{"reply" => "Yes."}}]}

    assert {:ok, _} =
             program([submit], :submit)
             |> Imp.call(%{ticket: "Can I pet it?", history: second.metadata.history})

    [replayed] = requests()

    assert shape(replayed) == [
             {:user, "[[ ## ticket ## ]]\nWhat is in the box?"},
             {:assistant, "It is a cat."},
             {:user, "[[ ## ticket ## ]]\nIs it awake?"},
             {:assistant, "It is asleep."},
             {:user, "[[ ## ticket ## ]]\nCan I pet it?"}
           ]

    refute Enum.any?(replayed, &(to_string(&1.content) =~ @note_start))
  end

  test "a submit-era thought replayed in a plain-text loop is followed by the line that it was not sent" do
    replies = [
      %{next_thought: "Let me think.", tool_calls: []},
      %{tool_calls: [%{id: "s1", name: "submit", arguments: %{"reply" => "It is a cat."}}]}
    ]

    {:ok, held} = program(replies, :submit) |> Imp.call(%{ticket: "What is in the box?"})
    _submit_era = requests()

    assert {:ok, _} =
             program([%{reply: "Yes.", tool_calls: []}], :auto)
             |> Imp.call(%{ticket: "Is it awake?", history: held.metadata.history})

    [replayed] = requests()

    assert shape(replayed) == [
             {:user, "[[ ## ticket ## ]]\nWhat is in the box?"},
             {:assistant, "Let me think."},
             {:user, "Your message above was not sent."},
             {:assistant, "It is a cat."},
             {:user, "[[ ## ticket ## ]]\nIs it awake?"}
           ]
  end

  # The requests of a conversation held only in a plain-text loop are those
  # 0.14.0 sent: its text steps are answers, so no line is added.
  test "a plain-text-only history replays exactly as before" do
    {:ok, first} =
      program([%{reply: "It is a cat.", tool_calls: []}], :auto)
      |> Imp.call(%{ticket: "What is in the box?"})

    look = %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}

    {:ok, second} =
      program([look, %{reply: "It is asleep.", tool_calls: []}], :auto)
      |> Imp.call(%{ticket: "Is it awake?", history: first.metadata.history})

    _held = requests()

    assert {:ok, _} =
             program([%{reply: "Yes.", tool_calls: []}], :auto)
             |> Imp.call(%{ticket: "Can I pet it?", history: second.metadata.history})

    [replayed] = requests()

    assert shape(replayed) == [
             {:user, "[[ ## ticket ## ]]\nWhat is in the box?"},
             {:assistant, "It is a cat."},
             {:user, "[[ ## ticket ## ]]\nIs it awake?"},
             {:assistant, ""},
             {:tool, "a cat"},
             {:assistant, "It is asleep."},
             {:user, "[[ ## ticket ## ]]\nCan I pet it?"}
           ]

    refute Enum.any?(replayed, &(to_string(&1.content) =~ "not sent"))
  end
end
