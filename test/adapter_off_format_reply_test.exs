defmodule AdapterOffFormatReplyTest do
  use ExUnit.Case, async: true

  # A reply that answers none of the requested outputs in the adapter's format
  # is a parse error, so `Imp.Predict`'s JSON fallback or a caller's retry
  # runs, whether the signature's outputs are required, optional or defaulted.
  # One rule for Chat, JSON and XML. A signature that names an output in
  # `metadata[:text_field]` is the one exception, read the same way by Chat
  # and XML.

  @prose "The capital of France is Paris."
  @json_object ~s({"reasoning": "It is the capital.", "answer": "Paris"})
  @chat_markers """
  [[ ## reasoning ## ]]
  It is the capital.

  [[ ## answer ## ]]
  Paris

  [[ ## completed ## ]]
  """
  @xml_tags "<reasoning>\nIt is the capital.\n</reasoning>\n\n<answer>\nParis\n</answer>"

  # Each adapter's off-format replies: every reply that is not its dialect.
  @off_format [
    {Imp.Adapter.XML, [prose: @prose, json_object: @json_object, chat_markers: @chat_markers]},
    {Imp.Adapter.Chat, [prose: @prose, json_object: @json_object, xml_tags: @xml_tags]},
    {Imp.Adapter.JSON,
     [
       object_with_other_keys: ~s({"result": "Paris", "why": "It is the capital."}),
       empty_object: "{}",
       prose: @prose,
       chat_markers: @chat_markers
     ]}
  ]

  @on_format [
    {Imp.Adapter.XML, @xml_tags},
    {Imp.Adapter.Chat, @chat_markers},
    {Imp.Adapter.JSON, @json_object}
  ]

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

  for {adapter, replies} <- @off_format, {reply_name, _reply} <- replies do
    test "#{inspect(adapter)}: a #{reply_name} reply is a parse error, whatever the outputs declare" do
      reply =
        @off_format |> Keyword.fetch!(unquote(adapter)) |> Keyword.fetch!(unquote(reply_name))

      for {name, signature} <- signatures() do
        assert {:error, %Imp.AdapterParseError{kind: kind}} =
                 unquote(adapter).parse(signature, reply, []),
               "#{name} accepted a #{unquote(reply_name)} reply"

        assert kind in [:missing_fields, :malformed]
      end
    end
  end

  test "a reply with none of the requested outputs names every output as missing" do
    for {adapter, reply} <- [
          {Imp.Adapter.XML, @prose},
          {Imp.Adapter.Chat, @prose},
          {Imp.Adapter.JSON, ~s({"result": "Paris"})}
        ],
        {_name, signature} <- signatures() do
      expected = Enum.map(signature.outputs, & &1.name)

      assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: ^expected}} =
               adapter.parse(signature, reply, [])
    end
  end

  test "a step-shaped signature without text_field metadata errors on prose too" do
    for adapter <- [Imp.Adapter.XML, Imp.Adapter.Chat] do
      assert {:error, %Imp.AdapterParseError{kind: :missing_fields}} =
               adapter.parse(step_signature(%{}), @prose, [])
    end
  end

  test "a reply in the adapter's format parses" do
    for {adapter, reply} <- @on_format, {_name, signature} <- signatures() do
      assert {:ok, prediction} = adapter.parse(signature, reply, [])
      assert Imp.get(prediction, :answer) == "Paris"
    end
  end

  test "a partial reply fills absent outputs the same way in every adapter" do
    two = Keyword.fetch!(signatures(), :two_required)
    lenient = Keyword.fetch!(signatures(), :two_optional_and_defaulted)

    only_answer = [
      {Imp.Adapter.XML, "<answer>Paris</answer>"},
      {Imp.Adapter.Chat, "[[ ## answer ## ]]\nParis"},
      {Imp.Adapter.JSON, ~s({"answer": "Paris"})}
    ]

    only_reasoning = [
      {Imp.Adapter.XML, "<reasoning>r</reasoning>"},
      {Imp.Adapter.Chat, "[[ ## reasoning ## ]]\nr"},
      {Imp.Adapter.JSON, ~s({"reasoning": "r"})}
    ]

    for {adapter, reply} <- only_answer do
      assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:reasoning]}} =
               adapter.parse(two, reply, [])
    end

    for {adapter, reply} <- only_reasoning do
      assert {:ok, prediction} = adapter.parse(lenient, reply, [])
      assert Imp.get(prediction, :reasoning) == "r"
      assert Imp.get(prediction, :answer) == "unknown"
    end
  end

  describe "a signature with a text_field" do
    test "prose is that field, trimmed, and the others take their defaults, in Chat and XML" do
      signature = step_signature(%{text_field: :next_thought})
      prose = "\n  I will answer without a tool: R&D is 3 < 4.  \n"

      for adapter <- [Imp.Adapter.XML, Imp.Adapter.Chat] do
        assert {:ok, prediction} = adapter.parse(signature, prose, [])

        assert Imp.get(prediction, :next_thought) ==
                 "I will answer without a tool: R&D is 3 < 4."

        assert Imp.get(prediction, :tool_calls) == []
      end
    end

    test "a blank reply is a step that said nothing, in Chat and XML" do
      signature = step_signature(%{text_field: :next_thought})

      for adapter <- [Imp.Adapter.XML, Imp.Adapter.Chat] do
        assert {:ok, prediction} = adapter.parse(signature, "  \n", [])
        assert Imp.get(prediction, :next_thought) == nil
        assert Imp.get(prediction, :tool_calls) == []
      end
    end

    test "a JSON {} is missing every output, under JSON and in the fallback" do
      signature = step_signature(%{text_field: :next_thought})

      assert {:error,
              %Imp.AdapterParseError{kind: :missing_fields, reason: [:next_thought, :tool_calls]}} =
               Imp.Adapter.JSON.parse(signature, "{}", [])

      replies = [~s({"next_thought": "I should look."}), "{}"]
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)
            Enum.at(replies, :counters.get(counter, 1) - 1)
          end
        )

      assert {:error, %Imp.AdapterParseError{kind: :missing_fields}} =
               signature
               |> Imp.Predict.new(lm: lm)
               |> Imp.Predict.call(%{question: "Capital?"})

      assert :counters.get(counter, 1) == 2
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
  end

  test "Imp.Predict falls back to JSON when an all-optional Chat reply is prose" do
    owner = self()
    {:ok, state} = Agent.start_link(fn -> :first end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :lm_call)

          Agent.get_and_update(state, fn
            :first -> {@prose, :second}
            :second -> {~s({"answer": "Paris"}), :second}
          end)
        end
      )

    program = Imp.Predict.new(Keyword.fetch!(signatures(), :one_optional), lm: lm)

    assert {:ok, prediction} = Imp.Predict.call(program, %{question: "Capital?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert_received :lm_call
    assert_received :lm_call
  end

  test "Chat reads the text beside native tool calls by the same rule" do
    one_optional = Keyword.fetch!(signatures(), :one_optional)

    assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:answer]}} =
             Imp.Adapter.Chat.parse(one_optional, %{text: @prose, tool_calls: []}, [])

    assert {:ok, prediction} =
             Imp.Adapter.Chat.parse(
               one_optional,
               %{text: "[[ ## answer ## ]]\nParis", tool_calls: []},
               []
             )

    assert Imp.get(prediction, :answer) == "Paris"
  end

  describe "a ReActV2 step that writes its fields in another format" do
    # The step reply of #231's capture: a thought and a tool call written as a
    # JSON object, or as Chat marker sections. It is not prose for
    # `next_thought`; the adapter's own format reads it, or the JSON fallback
    # does, and the tool runs.
    @capture_json ~s({"next_thought": "I should look.", "tool_calls": [{"name": "look", "arguments": {"thing": "France"}}]})
    @capture_markers """
    [[ ## next_thought ## ]]
    I should look.

    [[ ## tool_calls ## ]]
    [{"name": "look", "arguments": {"thing": "France"}}]
    """

    defp run_capture(adapter, replies) do
      owner = self()
      counter = :counters.new(1, [])

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            :counters.add(counter, 1, 1)
            Enum.at(replies, :counters.get(counter, 1) - 1)
          end
        )

      look =
        Imp.tool(:look, "Look at a thing", fn args ->
          send(owner, {:looked, args})
          "Its capital is Paris."
        end)

      agent = Imp.react("question -> answer", [look], lm: lm, adapter: adapter)
      assert {:ok, prediction} = Imp.call(agent, %{question: "Capital of France?"})
      {prediction, :counters.get(counter, 1)}
    end

    for adapter <- [Imp.Adapter.XML, Imp.Adapter.Chat] do
      test "#{inspect(adapter)}: a JSON object goes to the JSON fallback and its tool runs" do
        {prediction, calls} =
          run_capture(unquote(adapter), [@capture_json, @capture_json, "Paris."])

        assert_received {:looked, %{"thing" => "France"}}
        assert Imp.get(prediction, :answer) == "Paris."
        assert prediction.metadata.termination_reason == :answered
        assert calls == 3
      end
    end

    test "Imp.Adapter.XML: Chat marker sections go to the JSON fallback and the tool runs" do
      {prediction, calls} =
        run_capture(Imp.Adapter.XML, [@capture_markers, @capture_json, "Paris."])

      assert_received {:looked, %{"thing" => "France"}}
      assert Imp.get(prediction, :answer) == "Paris."
      assert calls == 3
    end

    test "Imp.Adapter.Chat: its own marker sections parse, with no fallback" do
      {prediction, calls} = run_capture(Imp.Adapter.Chat, [@capture_markers, "Paris."])

      assert_received {:looked, %{"thing" => "France"}}
      assert Imp.get(prediction, :answer) == "Paris."
      assert calls == 2
    end
  end
end
