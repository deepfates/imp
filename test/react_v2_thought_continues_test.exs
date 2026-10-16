defmodule ReActV2ThoughtContinuesTest do
  use ExUnit.Case, async: true

  # Under `finish: :submit`, a step that writes a thought and calls no tool is
  # followed by an ordinary step, with every tool and nothing forced, so a
  # model that said what it would do next can do it. A second such step in a
  # row is forced to `submit`.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)

  @thought %{next_thought: "Let me look in the box first.", tool_calls: []}
  @look %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}
  @submit %{tool_calls: [%{id: "s1", name: "submit", arguments: %{"reply" => "A cat."}}]}

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

  defp tool_choices(acc \\ []) do
    receive do
      {:request, _messages, opts} -> tool_choices([opts[:tool_choice] | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp call(replies, opts \\ []) do
    Imp.react(
      "ticket -> reply",
      [look()],
      [lm: scripted(self(), replies), finish: :submit] ++ opts
    )
    |> Imp.call(%{ticket: "What is in the box?"})
  end

  test "a thought, then a second in a row, is forced to submit" do
    assert {:ok, prediction} = call([@thought, @thought, @submit])
    assert Imp.get(prediction, :reply) == "A cat."
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :empty_tool_calls
    assert tool_choices() == ["auto", "auto", %{type: "tool", name: "submit"}]
  end

  test "a thought, then the tool it announced, and another thought continues too" do
    assert {:ok, prediction} = call([@thought, @look, @thought, @submit])
    assert Imp.get(prediction, :reply) == "A cat."
    assert prediction.metadata.termination_reason == :submit
    assert tool_choices() == ["auto", "auto", "auto", "auto"]

    results =
      for step <- prediction.metadata.history.messages, r <- step.tool_call_results, do: r.result

    assert "a cat" in results
  end

  test "the step limit still ends the turn with the forced submit" do
    assert {:ok, prediction} = call([@thought, @submit], max_iters: 1)
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :max_iters
    assert tool_choices() == ["auto", %{type: "tool", name: "submit"}]
  end

  test "a deadline that has already passed makes no forced submit" do
    owner = self()

    slow_look =
      Imp.tool(:look, "Look at a thing", fn _arguments ->
        Process.sleep(20)
        "a cat"
      end)

    program =
      Imp.react("ticket -> reply, confidence: float", [slow_look],
        lm: scripted(owner, [@look, @submit]),
        max_iters: 1
      )

    assert {:ok, prediction} =
             Imp.Deadline.with_deadline(10, fn ->
               Imp.call(program, %{ticket: "What is in the box?"})
             end)

    assert prediction.metadata.termination_reason == :incomplete
    assert prediction.metadata.termination_cause == :deadline_exceeded
    assert tool_choices() == ["auto"]
  end

  test "extracted outputs are recorded in the history" do
    replies = [
      @thought,
      @thought,
      %{next_thought: "A cat, I think.", tool_calls: []},
      %{reasoning: "The model said so.", reply: "A cat."}
    ]

    assert {:ok, prediction} = call(replies)
    assert prediction.metadata.termination_reason == :extracted

    last = List.last(prediction.metadata.history.messages)
    assert last.reply == "A cat."
    assert last.tool_calls.tool_calls == []
  end

  test "a thought of only whitespace is not continued: the same request would be sent again" do
    assert {:ok, prediction} = call([%{next_thought: "  \n ", tool_calls: []}, @submit])
    assert prediction.metadata.termination_reason == :forced_submit
    assert tool_choices() == ["auto", %{type: "tool", name: "submit"}]
  end

  test "resuming after an extracted turn does not end on the model's turn" do
    replies = [
      @thought,
      @thought,
      %{next_thought: "A cat, I think.", tool_calls: []},
      %{reasoning: "The model said so.", reply: "A cat."},
      @submit
    ]

    lm = scripted(self(), replies)
    program = Imp.react("ticket -> reply", [look()], lm: lm, finish: :submit)
    assert {:ok, extracted} = Imp.call(program, %{ticket: "What is in the box?"})
    assert extracted.metadata.termination_reason == :extracted
    _first_turn = tool_choices()

    assert {:ok, _resumed} =
             Imp.call(program, %{history: extracted.metadata.history, max_iters: 0})

    assert_received {:request, messages, _opts}
    assert List.last(messages).role != :assistant
  end

  # The process's deadline passes during the request named first; no request
  # after it is sent, and the turn ends without an answer.
  @slow 20
  @refusal {:error,
            %Imp.LMError{
              status: 400,
              message:
                "Invalid value for 'tool_choice': supported string values are none, auto, required"
            }}

  for {name, signature, finish, replies} <- [
        {"the continued step", "ticket -> reply", :submit, [:slow_thought]},
        {"the required retry", "ticket -> reply, confidence: float", :auto,
         [:thought, :slow_refusal]},
        {"the extractor", "ticket -> reply, confidence: float", :auto, [:thought, :slow_thought]}
      ] do
    @signature signature
    @finish finish
    @replies replies

    test "a deadline that passes before #{name} sends no request" do
      owner = self()
      {:ok, agent} = Agent.start_link(fn -> @replies end)

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, opts ->
            send(owner, {:request, [], opts})

            case Agent.get_and_update(agent, fn
                   [next | rest] -> {next, rest}
                   [] -> {:unexpected, []}
                 end) do
              :thought ->
                @thought

              :slow_thought ->
                Process.sleep(@slow)
                @thought

              :slow_refusal ->
                Process.sleep(@slow)
                @refusal
            end
          end
        )

      program = Imp.react(@signature, [look()], lm: lm, finish: @finish)

      assert {:ok, prediction} =
               Imp.Deadline.with_deadline(10, fn ->
                 Imp.call(program, %{ticket: "What is in the box?"})
               end)

      assert prediction.metadata.termination_reason == :incomplete
      assert prediction.metadata.termination_cause == :deadline_exceeded
      assert length(tool_choices()) == length(@replies)
    end
  end
end
