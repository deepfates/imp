defmodule ReActV2FinishSubmitTest do
  use ExUnit.Case, async: true

  # `finish: :submit` ends a one-text-output turn through `submit`, as DSPy's
  # ReActV2 ends every turn: text without a tool call is a thought, and the
  # forced `submit` follows. That forced request, for every signature with
  # `submit`, must not end on the model's own message, which Mistral and
  # Gemini refuse.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "seen" end)

  @thought %{next_thought: "Now let me look at the box.", tool_calls: []}
  @look %{next_thought: "Looking.", tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}

  # Replies in order; each request is sent to the test with its options.
  defp scripted(owner, replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        send(owner, {:request, messages, opts})

        Agent.get_and_update(agent, fn
          [reply | rest] -> {reply.(opts), rest}
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

  defp reply(value), do: fn _opts -> value end

  defp submit(arguments),
    do: reply(%{tool_calls: [%{id: "s", name: "submit", arguments: arguments}]})

  test "with finish: :submit, text without a tool call is a thought, and submit answers" do
    program =
      Imp.react("intent -> answer", [look()],
        lm: scripted(self(), [reply(@thought), submit(%{answer: "A cat."})]),
        finish: :submit
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "What is in the box?"})
    assert Imp.get(prediction, :answer) == "A cat."
    assert prediction.metadata.termination_reason == :forced_submit
    assert prediction.metadata.termination_cause == :empty_tool_calls

    [{_step, step_opts}, {_forced, forced_opts}] = requests()
    assert Enum.map(step_opts[:tools], & &1.function.name) == ["look", "submit"]
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}

    # The thought stays in the history as the model's step.
    [thought_step, _submit_step] = prediction.metadata.history.messages
    assert thought_step.next_thought == "Now let me look at the box."

    runner = fn _arguments -> "seen" end
    registry = Imp.Saving.Registry.new(look_runner: runner)

    dumped =
      Imp.react("intent -> answer", [Imp.tool(:look, "Look at a thing", runner)], finish: :submit)
      |> Imp.dump(registry: registry)

    assert dumped["finish"] == "submit"
    loaded = Imp.load!(dumped, registry: registry)
    assert loaded.finish == :submit
    assert Map.has_key?(loaded.tools, :submit)
    assert Imp.load!(Map.delete(dumped, "finish"), registry: registry).finish == :auto
  end

  # Every way a forced request is sent after a thought-only step: the named
  # `tool_choice`, the "required" retry when the provider refuses the name,
  # and the extractor when it refuses both; with and without a note; with
  # the thought as the first step and after a tool step.
  defp forced_reply(:submit), do: submit(%{answer: "A cat.", confidence: 1.0})
  defp forced_reply(:extract), do: reply(%{reasoning: "Seen.", answer: "A cat.", confidence: 1.0})

  defp forced_reply(:refused),
    do:
      reply(
        {:error, %Imp.LMError{status: 400, message: "only `auto` is supported for `tool_choice`"}}
      )

  for {provider, forced_replies} <- [
        honours_named: [:submit],
        honours_required: [:refused, :submit],
        auto_only: [:refused, :refused, :extract]
      ],
      {start, steps} <- [first_step: 0, after_a_tool: 1],
      note <- [nil, "Answer now."] do
    @forced_replies forced_replies
    @steps steps
    @note note

    test "#{provider}, #{start}, note #{inspect(note)}: no forced request ends on the model's turn" do
      replies =
        List.duplicate(reply(@look), @steps) ++
          [reply(@thought)] ++ Enum.map(@forced_replies, &forced_reply/1)

      program =
        Imp.react("intent -> answer, confidence: float", [look()],
          lm: scripted(self(), replies),
          last_request_note: @note
        )

      assert {:ok, prediction} = Imp.call(program, %{intent: "What is in the box?"})
      assert Imp.get(prediction, :answer) == "A cat."
      assert prediction.metadata.termination_reason in [:forced_submit, :extracted]

      forced = Enum.drop(requests(), @steps + 1)
      assert length(forced) == length(@forced_replies)

      for {messages, _opts} <- forced do
        assert List.last(messages).role != :assistant
        # The model still reads the thought it wrote.
        assert Enum.any?(messages, &(to_string(&1.content) =~ "Now let me look at the box."))
      end
    end
  end
end
