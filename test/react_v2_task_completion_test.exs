defmodule ReActV2TaskCompletionTest do
  use ExUnit.Case, async: true

  defmodule WrittenCallsLM do
    @behaviour Imp.LM
    defstruct [:handler]

    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(_), do: false
  end

  test "the task declaration supplies the sole text field and its description" do
    signature =
      Imp.signature(%{
        inputs: [:intent],
        outputs: [%{name: "summary", desc: "Leave empty to say nothing."}]
      })

    agent = Imp.react(signature, [])
    assert [text, _calls] = agent.react.signature.outputs
    assert text.name == :summary
    assert text.desc == "Leave empty to say nothing."
    assert agent.react.signature.metadata.text_field == :summary
    refute Enum.any?(agent.react.signature.outputs, &(&1.name == :next_thought))
  end

  for name <- [:answer, :summary, :next_thought, :text, :tool_calls, :agent_tool_calls, :history],
      adapter <- [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML] do
    test "#{name} completes via #{inspect(adapter)} and survives history replay" do
      name = unquote(name)
      owner = self()

      lm =
        Imp.LM.Static.new(
          handler: fn messages, _ ->
            send(owner, {:request, messages})

            case unquote(adapter) do
              Imp.Adapter.JSON -> Jason.encode!(%{name => "done"})
              Imp.Adapter.XML -> "<#{name}>done</#{name}>"
              _ -> "done"
            end
          end
        )

      agent =
        Imp.react(Imp.signature(%{inputs: [:intent], outputs: [name]}), [],
          lm: lm,
          adapter: unquote(adapter)
        )

      # Native content plus calls is a transport envelope even when an output
      # happens to be called text or tool_calls.
      assert {:ok, parsed} =
               Imp.Adapter.Chat.parse(agent.react.signature, %{text: "done", tool_calls: []}, [])

      assert Imp.get(parsed, name) == "done"
      assert {:ok, prediction} = Imp.call(agent, %{intent: "go"})
      assert Imp.get(prediction, name) == "done"
      assert {:ok, _} = Imp.call(agent, %{intent: "again", history: prediction.metadata.history})
      assert_received {:request, _first}
      assert_received {:request, replay}
      assert Enum.any?(replay, &(&1.role == :assistant and &1.content == "done"))
    end
  end

  test "legacy demos project their text and calls even when the task is named tool_calls" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _ ->
          send(owner, {:demo_request, messages})
          "done"
        end
      )

    agent =
      Imp.react("intent -> tool_calls", [],
        lm: lm,
        demos: [%{intent: "earlier", next_thought: "legacy text", tool_calls: []}]
      )

    assert {:ok, _} = Imp.call(agent, %{intent: "now"})
    assert_received {:demo_request, messages}
    assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "legacy text"))
    refute Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "Not supplied"))
  end

  test "a current demo's task field takes precedence over an input named next_thought" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _ ->
          send(owner, {:demo_request, messages})
          "done"
        end
      )

    agent =
      Imp.react("next_thought -> answer", [],
        lm: lm,
        demos: [%{next_thought: "the input", answer: "the output"}]
      )

    assert {:ok, _} = Imp.call(agent, %{next_thought: "now"})
    assert_received {:demo_request, messages}
    assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "the output"))
    refute Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "the input"))
  end

  test "a task named tool_calls can call a tool textually and replay it without changing roles" do
    owner = self()
    count = :counters.new(1, [])

    tool =
      Imp.tool(:look, "Look", fn _ ->
        send(owner, :looked)
        "seen"
      end)

    lm = %WrittenCallsLM{
      handler: fn messages, _ ->
        :counters.add(count, 1, 1)

        case :counters.get(count, 1) do
          1 ->
            %{tool_calls: "checking", agent_tool_calls: [%{name: "look", arguments: %{}}]}

          2 ->
            send(owner, {:written_replay, messages})
            %{tool_calls: "done", agent_tool_calls: []}
        end
      end
    }

    agent = Imp.react("intent -> tool_calls", [tool], lm: lm)
    assert {:ok, prediction} = Imp.call(agent, %{intent: "go"})
    assert Imp.get(prediction, :tool_calls) == "done"
    assert_received :looked
    refute_received :looked
    assert_received {:written_replay, messages}
    assistant = Enum.find(messages, &(&1.role == :assistant))
    assert assistant.content =~ "[[ ## tool_calls ## ]]\nchecking"
    assert assistant.content =~ "[[ ## agent_tool_calls ## ]]"
    refute assistant.content =~ "next_thought"
  end

  test "blank completion stays blank in one request, without a semantic prose filter" do
    for text <- ["", "No reply needed."] do
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _, _ ->
            :counters.add(counter, 1, 1)
            text
          end
        )

      assert {:ok, prediction} =
               Imp.call(Imp.react("intent -> answer", [], lm: lm), %{intent: "go"})

      assert Imp.get(prediction, :answer) == if(text == "", do: nil, else: text)
      assert :counters.get(counter, 1) == 1
    end
  end
end
