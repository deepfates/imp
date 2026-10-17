defmodule ReActV2HostAnswerTurnTest do
  use ExUnit.Case, async: true

  # A turn a host stores with the task's inputs and its answer, and no step of
  # the loop's own (a conversation's recap, say), is replayed as that answer
  # under every ending and either history replay: the model reads the reply
  # it is told it gave. Under `finish: :submit` and `:tools` it showed only
  # its inputs.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)
  defp send_tool, do: Imp.tool(:send, "Send the reply", fn _arguments -> "sent" end)

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

  defp shape(messages), do: Enum.map(tl(messages), &{&1.role, to_string(&1.content)})

  defp program(:auto, replay),
    do:
      Imp.react("ticket -> reply", [look()],
        lm: scripted(self(), [%{reply: "Yes.", tool_calls: []}]),
        finish: :auto,
        history_replay: replay
      )

  defp program(:submit, replay),
    do:
      Imp.react("ticket -> reply", [look()],
        lm:
          scripted(self(), [
            %{tool_calls: [%{id: "s1", name: "submit", arguments: %{"reply" => "Yes."}}]}
          ]),
        finish: :submit,
        history_replay: replay
      )

  defp program(:tools, replay),
    do:
      Imp.react("ticket -> reply", [look(), send_tool()],
        lm: scripted(self(), [%{tool_calls: [%{id: "s1", name: "send", arguments: %{}}]}]),
        finish: :tools,
        finish_on: %{send: fn _arguments, _result, _inputs -> {:finish, %{reply: "sent"}} end},
        history_replay: replay
      )

  @recap Imp.History.new([
           %{
             ticket: "The earlier part of this conversation is summarised in your recap of it.",
             reply: "We talked about a cat in a box."
           }
         ])

  for finish <- [:auto, :submit, :tools], replay <- [:trajectory, :actions] do
    test "finish: #{finish}, history_replay: #{replay}" do
      program = program(unquote(finish), unquote(replay))
      assert {:ok, _prediction} = Imp.call(program, %{ticket: "Is it awake?", history: @recap})

      [request] = requests()

      assert shape(request) == [
               {:user,
                "[[ ## ticket ## ]]\nThe earlier part of this conversation is summarised in your recap of it."},
               {:assistant, "We talked about a cat in a box."},
               {:user, "[[ ## ticket ## ]]\nIs it awake?"}
             ]
    end
  end

  # The history the caller passed keeps the turn as it was written.
  test "the stored turn is unchanged in the history returned" do
    assert {:ok, prediction} =
             Imp.call(program(:submit, :trajectory), %{ticket: "Is it awake?", history: @recap})

    assert hd(prediction.metadata.history.messages) == hd(@recap.messages)
  end
end
