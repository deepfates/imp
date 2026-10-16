defmodule ReActV2HistoryReplayTest do
  use ExUnit.Case, async: true

  # `history_replay: :actions` shows earlier turns as their inputs, the calls
  # they made with the results, and their outputs, without the text and
  # reasoning written beside the calls. The current turn is shown whole, and
  # the history the prediction returns keeps every step.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)

  defp scripted(owner, replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        send(owner, {:request, messages, opts})

        Agent.get_and_update(agent, fn
          [reply | rest] -> {reply, rest}
          [] -> {%{tool_calls: []}, []}
        end)
      end
    )
  end

  # An earlier turn: a call with narration beside it, a thought-only step,
  # then the answer.
  defp earlier do
    {:ok, first} =
      Imp.react("ticket -> reply", [look()],
        lm:
          scripted(self(), [
            %{
              reply: "Earlier narration beside a call.",
              tool_calls: [%{id: "c0", name: "look", arguments: %{}}]
            },
            %{reply: "A cat.", tool_calls: []}
          ])
      )
      |> Imp.call(%{ticket: "What is in the box?"})

    flush()
    [call, answer] = first.metadata.history.messages
    thought = %{next_thought: "An earlier thought nobody answered.", tool_calls: []}
    Imp.History.new([call, thought, answer])
  end

  defp flush do
    receive do
      {:request, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp texts(messages), do: Enum.map_join(messages, "\n", &to_string(&1.content))

  defp call(replay) do
    Imp.react("ticket -> reply", [look()],
      lm:
        scripted(self(), [
          %{
            reply: "This turn's narration.",
            tool_calls: [%{id: "c1", name: "look", arguments: %{}}]
          },
          "Still a cat."
        ]),
      history_replay: replay
    )
    |> Imp.call(%{ticket: "And now?", history: earlier()})
  end

  defp second_request do
    receive do
      {:request, _first, _opts} ->
        receive do
          {:request, messages, _opts} -> messages
        end
    end
  end

  test ":actions leaves earlier narration and thoughts out of the request, and keeps the current turn whole" do
    assert {:ok, prediction} = call(:actions)
    text = texts(second_request())

    refute text =~ "Earlier narration beside a call."
    refute text =~ "An earlier thought nobody answered."
    # The earlier call, its result, the answer and the current turn remain.
    assert text =~ "What is in the box?"
    assert text =~ "a cat"
    assert text =~ "A cat."
    assert text =~ "This turn's narration."

    # The history returned keeps everything.
    kept = prediction.metadata.history.messages |> Enum.map(&inspect/1) |> Enum.join()
    assert kept =~ "Earlier narration beside a call."
    assert kept =~ "An earlier thought nobody answered."
  end

  test ":trajectory, the default, shows earlier steps whole" do
    assert {:ok, _prediction} = call(:trajectory)
    text = texts(second_request())
    assert text =~ "Earlier narration beside a call."
    assert text =~ "An earlier thought nobody answered."
  end
end
