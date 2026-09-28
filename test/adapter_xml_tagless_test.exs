defmodule AdapterXMLTaglessTest do
  use ExUnit.Case, async: true

  # A reply to an XML request that has none of the requested output tags did
  # not answer in this format. It is a parse error, so `Imp.Predict`'s JSON
  # fallback or a caller's retry runs, whether the signature's outputs are
  # required, optional or defaulted. The output a signature names in
  # `metadata[:text_field]` is the one exception, read as `Imp.Adapter.Chat`
  # reads it.

  @replies %{
    prose: "The capital of France is Paris.",
    json_object: ~s({"reasoning": "It is the capital.", "answer": "Paris"}),
    chat_markers: """
    [[ ## reasoning ## ]]
    It is the capital.

    [[ ## answer ## ]]
    Paris

    [[ ## completed ## ]]
    """
  }

  defp output(name, metadata \\ %{}),
    do: Imp.Signature.Field.new(%{name: name, metadata: metadata}, :output)

  defp signature(outputs, metadata \\ %{}) do
    %Imp.Signature{
      inputs: [Imp.Signature.Field.new(%{name: :question}, :input)],
      outputs: outputs,
      metadata: metadata
    }
  end

  defp signatures do
    [
      one_required: signature([output(:answer)]),
      one_optional: signature([output(:answer, %{optional: true})]),
      one_defaulted: signature([output(:answer, %{default: "unknown"})]),
      two_required: signature([output(:reasoning), output(:answer)]),
      two_optional_and_defaulted:
        signature([output(:reasoning, %{optional: true}), output(:answer, %{default: "unknown"})])
    ]
  end

  defp step_signature(metadata) do
    signature(
      [
        output(:next_thought, %{optional: true}),
        Imp.Signature.Field.new(
          %{name: :tool_calls, type: :array, metadata: %{default: []}},
          :output
        )
      ],
      metadata
    )
  end

  for {reply_name, _reply} <- @replies do
    test "a #{reply_name} reply is missing every output, whatever the outputs declare" do
      reply = Map.fetch!(@replies, unquote(reply_name))

      for {name, signature} <- signatures() do
        expected = Enum.map(signature.outputs, & &1.name)

        assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: ^expected}} =
                 Imp.Adapter.XML.parse(signature, reply, []),
               "#{name} accepted a #{unquote(reply_name)} reply"
      end
    end
  end

  test "a step signature without text_field metadata errors on prose too" do
    assert {:error, %Imp.AdapterParseError{kind: :missing_fields}} =
             Imp.Adapter.XML.parse(step_signature(%{}), @replies.prose, [])
  end

  test "a reply with the requested tags parses" do
    reply = "<reasoning>\nIt is the capital.\n</reasoning>\n\n<answer>\nParis\n</answer>"

    for {_name, signature} <- signatures() do
      assert {:ok, prediction} = Imp.Adapter.XML.parse(signature, reply, [])
      assert Imp.get(prediction, :answer) == "Paris"
    end
  end

  test "a partial reply fills absent outputs as Chat does" do
    [
      one_required: _,
      one_optional: _,
      one_defaulted: _,
      two_required: two,
      two_optional_and_defaulted: lenient
    ] =
      signatures()

    xml = "<answer>Paris</answer>"
    chat = "[[ ## answer ## ]]\nParis"

    assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:reasoning]}} =
             Imp.Adapter.XML.parse(two, xml, [])

    assert Imp.Adapter.Chat.parse(two, chat, []) == Imp.Adapter.XML.parse(two, xml, [])

    assert {:ok, prediction} = Imp.Adapter.XML.parse(lenient, "<reasoning>r</reasoning>", [])
    assert Imp.get(prediction, :reasoning) == "r"
    assert Imp.get(prediction, :answer) == "unknown"

    assert Imp.Adapter.Chat.parse(lenient, "[[ ## reasoning ## ]]\nr", []) ==
             Imp.Adapter.XML.parse(lenient, "<reasoning>r</reasoning>", [])
  end

  describe "a signature with a text_field" do
    test "prose is that field, trimmed, and the others take their defaults, as in Chat" do
      signature = step_signature(%{text_field: :next_thought})
      prose = "\n  I will answer without a tool: R&D is 3 < 4.  \n"

      assert {:ok, prediction} = Imp.Adapter.XML.parse(signature, prose, [])
      assert Imp.get(prediction, :next_thought) == "I will answer without a tool: R&D is 3 < 4."
      assert Imp.get(prediction, :tool_calls) == []
      assert {:ok, prediction} == Imp.Adapter.Chat.parse(signature, prose, [])
    end

    test "a reply with a requested tag parses by tags" do
      signature = step_signature(%{text_field: :next_thought})

      assert {:ok, prediction} =
               Imp.Adapter.XML.parse(signature, "<next_thought>\ndone.\n</next_thought>", [])

      assert Imp.get(prediction, :next_thought) == "done."
    end

    test "a ReActV2 step under XML answers with one prose reply and one LM call" do
      owner = self()

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            send(owner, :lm_call)
            "Paris."
          end
        )

      look = Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)
      agent = Imp.react("question -> answer", [look], lm: lm, adapter: Imp.Adapter.XML)

      assert {:ok, prediction} = Imp.call(agent, %{question: "Capital of France?"})
      assert Imp.get(prediction, :answer) == "Paris."
      assert prediction.metadata.termination_reason == :answered
      assert_received :lm_call
      refute_received :lm_call
    end

    test "a blank reply is not a thought" do
      signature = step_signature(%{text_field: :next_thought})

      assert {:error, %Imp.AdapterParseError{kind: :missing_fields}} =
               Imp.Adapter.XML.parse(signature, "  \n", [])
    end
  end
end
