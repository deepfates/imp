defmodule Imp.Adapter.ChatWrittenHistoryTest do
  use ExUnit.Case, async: true

  # A request whose signature describes a tool-calls output replays its stored
  # turns as text: the turn's outputs as the assistant's message, then the
  # results. A turn that recorded no output and no call has no assistant
  # message; any recorded output, an answer included, keeps it.

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  @filler "Not supplied for this conversation history message."

  defp text_only_lm(replies) do
    owner = self()
    counter = :counters.new(1, [])

    %TextOnlyLM{
      handler: fn messages, _opts ->
        :counters.add(counter, 1, 1)
        send(owner, {:request, messages})
        Enum.at(replies, :counters.get(counter, 1) - 1)
      end
    }
  end

  test "a Predict step with a tool-calls field keeps an answered turn's assistant message" do
    signature =
      Imp.Signature.ensure("question, history, tools: array -> answer, tool_calls: array")

    signature = %{
      signature
      | metadata: Map.put(signature.metadata, :tool_calls_field, :tool_calls)
    }

    history = Imp.History.new([%{question: "q1", answer: "42", tool_calls: []}])

    program =
      Imp.Predict.new(signature,
        lm: text_only_lm(["[[ ## answer ## ]]\n43\n\n[[ ## tool_calls ## ]]\n[]"])
      )

    assert {:ok, _prediction} =
             Imp.Predict.call(program, %{question: "q2", history: history, tools: []})

    assert_received {:request, messages}
    index = Enum.find_index(messages, &(&1.role == :user and &1.content =~ "q1"))
    assert %{role: :assistant, content: answered} = Enum.at(messages, index + 1)
    assert answered =~ "42"
  end

  test "a ReActV2 step that answered with nothing replays with no assistant message" do
    lm = text_only_lm(["", "[[ ## next_thought ## ]]\nsecond\n\n[[ ## tool_calls ## ]]\n[]"])
    look = Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => true} end)
    program = Imp.react("intent -> answer", [look], lm: lm)

    assert {:ok, first} = Imp.call(program, %{intent: "hello"})
    assert first.metadata.termination_reason == :answered
    assert_received {:request, _first}

    assert {:ok, _second} =
             Imp.call(program, %{intent: "again", history: first.metadata.history})

    assert_received {:request, replayed}
    refute Enum.any?(replayed, &(to_string(&1.content) =~ @filler))
    index = Enum.find_index(replayed, &(&1.role == :user and &1.content =~ "hello"))
    refute Enum.at(replayed, index + 1).role == :assistant
  end
end
