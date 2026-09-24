defmodule AdapterChatTextStepTest do
  use ExUnit.Case, async: true

  # A native tool loop asks a step for a thought and tool calls. A model that
  # answers in plain prose and calls nothing has said something and called
  # nothing; `signature.metadata[:text_step]` says which output that prose is.
  # Without that metadata a marker-free completion is still a parse failure, so
  # `Imp.Predict`'s JSON-adapter fallback still rescues an ordinary program.

  defp react_signature do
    %Imp.Signature{
      inputs: [Imp.Signature.Field.new(%{name: :question}, :input)],
      outputs: [
        Imp.Signature.Field.new(%{name: :next_thought, metadata: %{optional: true}}, :output),
        Imp.Signature.Field.new(
          %{name: :tool_calls, type: :array, metadata: %{default: []}},
          :output
        )
      ],
      metadata: %{text_step: :next_thought}
    }
  end

  defp counting_lm(response) do
    owner = self()

    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        send(owner, {:lm_call, messages})
        response
      end
    )
  end

  defp call_count do
    receive do
      {:lm_call, _messages} -> 1 + call_count()
    after
      0 -> 0
    end
  end

  test "a marker-free completion is the prose field, with no tool calls" do
    prose = "I think the answer is Paris, but I am not going to look it up."

    assert {:ok, prediction} = Imp.Adapter.Chat.parse(react_signature(), prose, [])
    assert Imp.get(prediction, :next_thought) == prose
    assert Imp.get(prediction, :tool_calls) == []
  end

  test "surrounding whitespace is trimmed and multi-line prose is kept whole" do
    prose = "\n  First line.\n\nSecond line.  \n"

    assert {:ok, prediction} = Imp.Adapter.Chat.parse(react_signature(), prose, [])
    assert Imp.get(prediction, :next_thought) == "First line.\n\nSecond line."
  end

  test "a marked completion still parses by markers" do
    text = """
    [[ ## next_thought ## ]]
    looking it up

    [[ ## tool_calls ## ]]
    []
    """

    assert {:ok, prediction} = Imp.Adapter.Chat.parse(react_signature(), text, [])
    assert Imp.get(prediction, :next_thought) == "looking it up"
  end

  test "a marker anywhere means marker parsing, not prose" do
    text = """
    Some preamble the model wrote.

    [[ ## next_thought ## ]]
    looking it up
    """

    assert {:ok, prediction} = Imp.Adapter.Chat.parse(react_signature(), text, [])
    assert Imp.get(prediction, :next_thought) == "looking it up"
    assert Imp.get(prediction, :tool_calls) == []
  end

  # The step shape is total by declaration: `next_thought` is optional and
  # `tool_calls` defaults to none, so a blank completion is a step that said
  # and called nothing rather than a parse failure and a second LM call.
  test "a blank completion is a step that said nothing" do
    assert {:ok, prediction} = Imp.Adapter.Chat.parse(react_signature(), "   \n  ", [])
    assert Imp.get(prediction, :next_thought) == nil
    assert Imp.get(prediction, :tool_calls) == []
  end

  test "a prose step costs one LM call: no JSON-adapter fallback" do
    lm = counting_lm("I have nothing to look up.")

    program = Imp.Predict.Predict.new(react_signature(), lm: lm)

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "Capital?"})
    assert Imp.get(prediction, :next_thought) == "I have nothing to look up."
    assert Imp.get(prediction, :tool_calls) == []
    assert call_count() == 1
  end

  test "a signature without the metadata still fails, and the JSON fallback rescues it" do
    plain = Imp.Signature.new("question -> thought, answer")

    assert {:error, _reason} = Imp.Adapter.Chat.parse(plain, "just some prose", [])

    owner = self()
    {:ok, state} = Agent.start_link(fn -> :first end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:lm_call, messages})

          Agent.get_and_update(state, fn
            :first -> {"just some prose", :second}
            :second -> {~s({"thought": "thinking", "answer": "Paris"}), :second}
          end)
        end
      )

    program = Imp.Predict.Predict.new(plain, lm: lm)

    assert {:ok, prediction} = Imp.Predict.Predict.call(program, %{question: "Capital?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert call_count() == 2
  end
end
