defmodule ReActV2HistoryReplayTest do
  use ExUnit.Case, async: true

  # `history_replay: :actions` shows earlier turns as their inputs, the calls
  # they made with the results, and their outputs, without the text and
  # reasoning written beside the calls. The current turn is shown whole, and
  # the history the prediction returns keeps every step.

  defp look, do: Imp.tool(:look, "Look at a thing", fn %{"at" => at} -> "seen: #{at}" end)

  @schema %{"type" => "object", "properties" => %{"at" => %{"type" => "string"}}}
  defp look_tool,
    do: Imp.tool(:look, "Look at a thing", fn %{"at" => at} -> "seen: #{at}" end, schema: @schema)

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

  defp flush do
    receive do
      {:request, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp call_step(id, at, text),
    do: %{reply: text, tool_calls: [%{id: id, name: "look", arguments: %{"at" => at}}]}

  # An earlier turn: a call with narration and reasoning beside it, a
  # thought-only step, then the answer.
  defp earlier do
    {:ok, first} =
      Imp.react("ticket -> reply", [look_tool()],
        lm:
          scripted(self(), [
            call_step("c0", "the box", "Earlier narration."),
            %{reply: "A cat.", tool_calls: []}
          ])
      )
      |> Imp.call(%{ticket: "What is in the box?"})

    flush()
    [call, answer] = first.metadata.history.messages

    call =
      call
      |> Map.put(:reasoning_content, "earlier reasoning")
      |> Map.put(:reasoning_details, [%{"text" => "earlier detail"}])

    thought = %{next_thought: "An earlier thought nobody answered.", tool_calls: []}
    Imp.History.new([call, thought, answer])
  end

  defp program(replay, replies),
    do:
      Imp.react("ticket -> reply", [look_tool()],
        lm: scripted(self(), replies),
        history_replay: replay
      )

  defp last_request do
    receive do
      {:request, messages, _opts} ->
        receive do
          {:request, _, _} = next ->
            send(self(), next)
            last_request()
        after
          0 -> messages
        end
    end
  end

  defp assistant_with_call(messages, id),
    do:
      Enum.find(
        messages,
        &(&1.role == :assistant and
            Enum.any?(&1[:tool_calls] || [], fn c -> c[:id] == id or c["id"] == id end))
      )

  defp tool_result(messages, id),
    do:
      Enum.find(
        messages,
        &(&1.role == :tool and Enum.any?(&1[:tool_calls] || [], fn c -> c[:id] == id end))
      )

  test ":actions strips earlier narration, reasoning and thoughts, keeps calls paired with their results, and keeps the current turn whole" do
    replies = [
      call_step("c1", "the lid", "This turn's narration."),
      %{reply: "Still a cat.", tool_calls: []}
    ]

    assert {:ok, prediction} =
             Imp.call(program(:actions, replies), %{ticket: "And now?", history: earlier()})

    messages = last_request()
    text = Enum.map_join(messages, "\n", &inspect/1)

    refute text =~ "Earlier narration."
    refute text =~ "earlier reasoning"
    refute text =~ "earlier detail"
    refute text =~ "An earlier thought nobody answered."

    # The earlier call is still there, paired with its own result.
    earlier_call = assistant_with_call(messages, "c0")
    assert earlier_call
    assert tool_result(messages, "c0").content =~ "seen: the box"
    # The current turn is whole: its narration and its call with its result.
    assert text =~ "This turn's narration."
    assert tool_result(messages, "c1").content =~ "seen: the lid"
    assert text =~ "A cat."

    kept = inspect(prediction.metadata.history.messages)
    assert kept =~ "Earlier narration." and kept =~ "earlier reasoning"
  end

  test ":trajectory, the default, shows earlier steps whole" do
    replies = [%{reply: "Still a cat.", tool_calls: []}]

    assert {:ok, _} =
             Imp.call(program(:trajectory, replies), %{ticket: "And now?", history: earlier()})

    text = Enum.map_join(last_request(), "\n", &inspect/1)
    assert text =~ "Earlier narration."
    assert text =~ "An earlier thought nobody answered."
  end

  test "a resume with no new inputs keeps the in-progress turn whole, reasoning included" do
    # The history ends mid-turn: the turn's inputs, then a call with reasoning
    # beside it and its result, and no answer yet.
    {:ok, stopped} =
      Imp.react("ticket -> reply", [look_tool()],
        lm:
          scripted(self(), [
            %{
              next_thought: "Checking the lid.",
              tool_calls: [%{id: "c2", name: "look", arguments: %{"at" => "the lid"}}]
            }
          ]),
        finish: :tools,
        finish_on: %{look: fn _arguments, _result, _inputs -> :continue end},
        max_iters: 1
      )
      |> Imp.call(%{ticket: "And the lid?", history: earlier()})

    flush()
    {done, [current]} = Enum.split(stopped.metadata.history.messages, -1)
    in_progress = done ++ [Map.put(current, :reasoning_content, "current reasoning")]

    assert {:ok, _} =
             Imp.call(program(:actions, [%{reply: "Shut.", tool_calls: []}]), %{
               history: Imp.History.new(in_progress)
             })

    text = Enum.map_join(last_request(), "\n", &inspect/1)
    assert text =~ "Checking the lid."
    assert text =~ "current reasoning"
    refute text =~ "earlier reasoning"
  end

  test "a call with its own note and no inputs (a summary request) reads every passed turn as earlier" do
    assert {:ok, _} =
             Imp.call(program(:actions, ["Summary."]), %{
               history: earlier(),
               max_iters: 0,
               last_request_note: "Summarise this conversation."
             })

    text = Enum.map_join(last_request(), "\n", &inspect/1)
    refute text =~ "Earlier narration."
    assert text =~ "Summarise this conversation."
  end
end
