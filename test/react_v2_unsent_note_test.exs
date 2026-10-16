defmodule ReActV2UnsentNoteTest do
  use ExUnit.Case, async: true

  # Under `finish: :submit`, after a step that wrote a thought and called no
  # tool, the model is told that its message was not sent and how to go on.
  # The line follows every such step, in every request and on replay; only
  # the forced `submit`'s own last thought is shown on the user side instead.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _arguments -> "a cat" end)

  @thought %{next_thought: "Let me look in the box first.", tool_calls: []}
  @look %{tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}
  @note "Your message above was not sent. To reply, call `submit` with `answer` and " <>
          "`confidence`; to keep working, call a tool."

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  defp scripted(owner, replies, module \\ Imp.LM.Static) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    handler = fn messages, opts ->
      send(owner, {:request, messages, opts})

      Agent.get_and_update(agent, fn
        [reply | rest] -> {reply, rest}
        [] -> {%{tool_calls: []}, []}
      end)
    end

    if module == TextOnlyLM, do: %TextOnlyLM{handler: handler}, else: module.new(handler: handler)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages, _opts} -> requests([messages | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp submit(arguments),
    do: %{tool_calls: [%{id: "s1", name: "submit", arguments: arguments}]}

  defp call(replies, lm_module \\ Imp.LM.Static) do
    Imp.react("ticket -> answer, confidence: float", [look()],
      lm: scripted(self(), replies, lm_module),
      finish: :submit
    )
    |> Imp.call(%{ticket: "What is in the box?"})
  end

  test "the line names every output, and stays after the thought in later requests" do
    assert {:ok, prediction} =
             call([@thought, @look, submit(%{"answer" => "A cat.", "confidence" => 1.0})])

    assert prediction.metadata.termination_reason == :submit

    [_first, continued, after_look] = requests()

    assert continued |> Enum.take(-2) |> Enum.map(&Map.take(&1, [:role, :content])) == [
             %{role: :assistant, content: "Let me look in the box first."},
             %{role: :user, content: @note}
           ]

    # The next request is the continued one plus the newest exchange.
    assert Enum.take(after_look, length(continued)) == continued
  end

  test "the forced submit shows its last thought on the user side, with no line after it" do
    assert {:ok, prediction} =
             call([@thought, @thought, submit(%{"answer" => "A cat.", "confidence" => 1.0})])

    assert prediction.metadata.termination_reason == :forced_submit

    [_first, _continued, forced] = requests()

    assert forced |> Enum.take(-3) |> Enum.map(&Map.take(&1, [:role, :content])) == [
             %{role: :assistant, content: "Let me look in the box first."},
             %{role: :user, content: @note},
             %{role: :user, content: "[[ ## next_thought ## ]]\nLet me look in the box first."}
           ]
  end

  test "with written tool calls the line follows the thought, and the tool listing ends the request" do
    thought =
      "[[ ## next_thought ## ]]\nLet me look in the box first.\n\n[[ ## tool_calls ## ]]\n[]"

    submitted =
      ~s([[ ## next_thought ## ]]\nDone.\n\n[[ ## tool_calls ## ]]\n) <>
        ~s([{"name": "submit", "arguments": {"answer": "A cat.", "confidence": 1.0}}])

    assert {:ok, prediction} = call([thought, submitted], TextOnlyLM)
    assert prediction.metadata.termination_reason == :submit

    [_first, continued] = requests()
    [step, note, listing] = Enum.take(continued, -3)
    assert step.role == :assistant and step.content =~ "Let me look in the box first."
    assert note == %{role: :user, content: @note}
    assert listing.role == :user and listing.content =~ "[[ ## tools ## ]]"
  end

  defp shape(messages), do: Enum.map(messages, &{&1.role, to_string(&1.content)})

  defp thought_step(fields, thought),
    do:
      Map.merge(fields, %{
        next_thought: thought,
        tool_calls: %Imp.Adapter.Types.ToolCalls{tool_calls: []},
        tool_call_results: []
      })

  test "on replay, the line follows each unsent thought, and not one the extracted answer followed" do
    # A held turn: a thought, a second one (the forced request's), the forced
    # reply's thought, then the extracted answer, recorded as a silent step.
    history =
      Imp.History.new([
        thought_step(%{ticket: "What is in the box?"}, "Let me look."),
        thought_step(%{}, "Still looking."),
        thought_step(%{}, "A cat, I think."),
        %{
          answer: "A cat.",
          confidence: 0.5,
          tool_calls: %Imp.Adapter.Types.ToolCalls{tool_calls: []},
          tool_call_results: []
        }
      ])

    program =
      Imp.react("ticket -> answer, confidence: float", [look()],
        lm: scripted(self(), [submit(%{"answer" => "A dog.", "confidence" => 1.0})]),
        finish: :submit
      )

    assert {:ok, _} = Imp.call(program, %{ticket: "And now?", history: history})
    [replayed] = requests()

    assert replayed |> tl() |> shape() == [
             {:user, "[[ ## ticket ## ]]\nWhat is in the box?"},
             {:assistant, "Let me look."},
             {:user, @note},
             {:assistant, "Still looking."},
             {:user, @note},
             {:assistant, "A cat, I think."},
             {:user, "[[ ## ticket ## ]]\nAnd now?"}
           ]
  end

  test "a forced request with new inputs keeps the line after the held thought" do
    history = Imp.History.new([thought_step(%{ticket: "What is in the box?"}, "Let me look.")])

    program =
      Imp.react("ticket -> answer, confidence: float", [look()],
        lm: scripted(self(), [submit(%{"answer" => "A cat.", "confidence" => 1.0})]),
        finish: :submit
      )

    assert {:ok, prediction} =
             Imp.call(program, %{ticket: "And now?", history: history, max_iters: 0})

    assert prediction.metadata.termination_reason == :forced_submit
    [forced] = requests()

    assert forced |> Enum.take(-3) |> shape() == [
             {:assistant, "Let me look."},
             {:user, @note},
             {:user, "[[ ## ticket ## ]]\nAnd now?"}
           ]
  end
end
