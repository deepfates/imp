defmodule ReActV2FinishToolsTest do
  use ExUnit.Case, async: true

  # `finish: :tools`: only a `finish_on` tool ends the turn. Text without a
  # tool call is a thought, as under `finish: :submit`, but there is no
  # `submit` and nothing is forced: a second thought in a row, an empty step
  # or the step limit ends the turn `:incomplete`, with no further request.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)
  defp send_tool, do: Imp.tool(:send, "Send the reply", fn _arguments -> "sent" end)
  defp decline, do: Imp.tool(:decline, "Say nothing", fn _arguments -> "ok" end)

  @thought %{next_thought: "A cat, I think.", tool_calls: []}
  @look %{next_thought: "Looking first.", tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}
  @send %{tool_calls: [%{id: "s1", name: "send", arguments: %{}}]}

  defp finish_on,
    do: %{
      send: fn _arguments, _result, _inputs -> {:finish, %{reply: "sent"}} end,
      decline: fn _arguments, _result, _inputs -> {:finish, %{reply: ""}} end
    }

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

  defp requests(acc \\ []) do
    receive do
      {:request, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp program(replies, opts \\ []) do
    Imp.react(
      "ticket -> reply",
      [look(), send_tool(), decline()],
      [lm: scripted(self(), replies), finish: :tools, finish_on: finish_on()] ++ opts
    )
  end

  defp call(replies, opts \\ []),
    do: replies |> program(opts) |> Imp.call(%{ticket: "What is in the box?"})

  defp tool_names(opts), do: Enum.map(opts[:tools], & &1.function.name)

  test "a thought continues, the turn ends only through a finish_on tool, and nothing is submit" do
    assert {:ok, prediction} = call([@thought, @send])
    assert prediction.metadata.termination_reason == :finished_by_tool
    assert prediction.metadata.finished_by_tool == "send"
    assert Imp.get(prediction, :reply) == "sent"

    [{[system | _], first}, {second_messages, second}] = requests()
    assert tool_names(first) == ["look", "send", "decline"]
    assert first[:tool_choice] == "auto" and second[:tool_choice] == "auto"

    # The guidance names the ending tools; nothing asks for an answer in text.
    assert system.content =~ "The turn ends only when you call `decline` or `send`."
    refute system.content =~ "write it as plain text"
    refute system.content =~ "submit"

    # The thought stays the model's own message, then the default line.
    [thought, line] = Enum.take(second_messages, -2)
    assert thought.role == :assistant and thought.content =~ "A cat, I think."

    assert line == %{
             role: :user,
             content:
               "Your message above was not sent. To end the turn, call `decline` or `send`; " <>
                 "to keep working, call a tool."
           }
  end

  test "a second thought in a row ends the turn :incomplete, with no further request" do
    assert {:ok, prediction} = call([@thought, @thought, @send])
    assert prediction.metadata.termination_reason == :incomplete
    assert prediction.metadata.termination_cause == :empty_tool_calls
    refute Imp.Prediction.complete?(prediction)
    assert length(requests()) == 2
  end

  test "the step limit ends the turn :incomplete, and nothing is forced" do
    assert {:ok, prediction} = call([@look, @look], max_iters: 2)
    assert prediction.metadata.termination_reason == :incomplete
    assert prediction.metadata.termination_cause == :max_iters

    assert Enum.map(requests(), fn {_messages, opts} -> opts[:tool_choice] end) == [
             "auto",
             "auto"
           ]
  end

  test "a host's own unsent note replaces the default" do
    note = "Your message above was not sent. To speak, call `send`; to keep looking, call a tool."
    assert {:ok, _prediction} = call([@thought, @send], unsent_note: note)
    [_first, {messages, _opts}] = requests()
    assert List.last(messages) == %{role: :user, content: note}
  end

  test "finish: :tools without a finish_on tool is refused" do
    assert_raise ArgumentError, ~r/finish: :tools needs at least one finish_on tool/, fn ->
      Imp.react("ticket -> reply", [look()], finish: :tools)
    end
  end

  test "a call's own finish overrides the program's, for that call" do
    program = program(["In a box: a cat."])

    assert {:ok, prediction} =
             Imp.call(program, %{ticket: "What is in the box?", finish: :auto, max_iters: 0})

    assert Imp.get(prediction, :reply) == "In a box: a cat."
    assert prediction.metadata.termination_reason == :last_text

    # And the other way: a plain-text program called with `finish: :tools`.
    plain =
      Imp.react("ticket -> reply", [look(), send_tool(), decline()],
        lm: scripted(self(), [@thought, @thought]),
        finish_on: finish_on()
      )

    _ = requests()

    assert {:ok, prediction} = Imp.call(plain, %{ticket: "What is in the box?", finish: :tools})
    assert prediction.metadata.termination_reason == :incomplete
  end

  test "an answer recorded under :auto replays as an answer, with no unsent note" do
    history =
      Imp.History.new([
        %{ticket: "Hello?", next_thought: "Hi there.", reply: "Hi there.", tool_calls: []}
      ])

    assert {:ok, _prediction} =
             [@send] |> program() |> Imp.call(%{ticket: "And now?", history: history})

    [{messages, _opts}] = requests()
    assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "Hi there."))
    refute Enum.any?(messages, &(to_string(&1.content) =~ "was not sent"))
  end

  test "the program saves and loads with its ending, note and replay" do
    runner = fn _arguments -> "x" end
    finish = fn _arguments, _result, _inputs -> {:finish, %{reply: ""}} end
    registry = Imp.Saving.Registry.new(look_runner: runner, finish_cb: finish)

    dumped =
      Imp.react("ticket -> reply", [Imp.tool(:look, "Look", runner)],
        finish: :tools,
        finish_on: %{look: finish},
        unsent_note: "Not sent.",
        history_replay: :actions
      )
      |> Imp.dump(registry: registry)

    assert {dumped["finish"], dumped["unsent_note"], dumped["history_replay"]} ==
             {"tools", "Not sent.", "actions"}

    loaded = Imp.load!(dumped, registry: registry)

    assert {loaded.finish, loaded.unsent_note, loaded.history_replay} ==
             {:tools, "Not sent.", :actions}

    # A program that sets neither saves as before.
    plain =
      Imp.react("ticket -> reply", [Imp.tool(:look, "Look", runner)])
      |> Imp.dump(registry: registry)

    refute Map.has_key?(plain, "unsent_note") or Map.has_key?(plain, "history_replay")
  end

  test "a task input named finish is the input, not the call option" do
    program =
      Imp.react("start, finish -> reply", [look()],
        lm: scripted(self(), [%{reply: "Eight hours.", tool_calls: []}])
      )

    assert {:ok, prediction} = Imp.call(program, %{start: "9am", finish: "5pm"})
    assert Imp.get(prediction, :reply) == "Eight hours."
    [{messages, _opts}] = requests()
    assert List.last(messages).content =~ "5pm"
  end

  test "a passed deadline ends a :tools turn :deadline_exceeded, with no further request" do
    slow =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(self(), {:request, messages, opts})
          Process.sleep(30)
          @thought
        end
      )

    program =
      Imp.react("ticket -> reply", [look(), send_tool(), decline()],
        lm: slow,
        finish: :tools,
        finish_on: finish_on()
      )

    assert {:ok, prediction} =
             Imp.Deadline.with_deadline(10, fn -> Imp.call(program, %{ticket: "?"}) end)

    assert prediction.metadata.termination_reason == :incomplete
    assert prediction.metadata.termination_cause == :deadline_exceeded
  end

  test "a failed request gets one more ordinary step, once per turn" do
    {:ok, count} = Agent.start_link(fn -> 0 end)

    flaky = fn replies ->
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          n = Agent.get_and_update(count, &{&1, &1 + 1})

          case Enum.at(replies, n) do
            :fail -> raise "provider down"
            reply -> reply
          end
        end
      )
    end

    program = fn replies ->
      Agent.update(count, fn _ -> 0 end)

      Imp.react("ticket -> reply", [look(), send_tool(), decline()],
        lm: flaky.(replies),
        finish: :tools,
        finish_on: finish_on()
      )
    end

    assert {:ok, prediction} = Imp.call(program.([:fail, @send]), %{ticket: "?"})
    assert prediction.metadata.termination_reason == :finished_by_tool

    assert {:ok, prediction} = Imp.call(program.([:fail, :fail, @send]), %{ticket: "?"})
    assert prediction.metadata.termination_reason == :incomplete
    assert Agent.get(count, & &1) == 2
  end

  test "settings :tools would never use, a blank note and a call's :tools without finish_on are refused" do
    assert_raise ArgumentError, ~r/finish: :tools makes no last request/, fn ->
      program([], last_request_note: "Last one.")
    end

    assert_raise ArgumentError, ~r/unsent_note must say something/, fn ->
      program([], unsent_note: "  ")
    end

    assert {:error, {:invalid_react_v2_last_request_note, _}} =
             Imp.call(program([]), %{ticket: "?", last_request_note: "Last one."})

    plain = Imp.react("ticket -> reply", [look()], lm: scripted(self(), []))

    assert {:error, {:invalid_react_v2_finish, _}} =
             Imp.call(plain, %{ticket: "?", finish: :tools})

    runner = fn _arguments -> "x" end
    finish = fn _arguments, _result, _inputs -> {:finish, %{reply: ""}} end
    registry = Imp.Saving.Registry.new(look_runner: runner, finish_cb: finish)

    dumped =
      Imp.react("ticket -> reply", [Imp.tool(:look, "Look", runner)],
        finish: :tools,
        finish_on: %{look: finish}
      )
      |> Imp.dump(registry: registry)

    assert_raise ArgumentError, ~r/finish: :tools needs at least one finish_on tool/, fn ->
      dumped |> Map.put("finish_on", %{}) |> Imp.load!(registry: registry)
    end
  end
end
