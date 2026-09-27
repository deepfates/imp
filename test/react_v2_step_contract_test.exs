defmodule ReActV2StepContractTest do
  use ExUnit.Case, async: true

  # A ReActV2 step asks for one thing, whichever adapter formats it. With an
  # LM that calls tools natively, the tools are sent and no request of the
  # step (its adapter's, the JSON fallback's, a demo's, a stored turn's)
  # describes a `tool_calls` output. With an LM that cannot, the step
  # describes `tool_calls`, sends no tools, and tells the model to leave it
  # empty when it answers. Either way, a reply that follows the guidance is
  # the answer.

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  @in_field "When the final answer is ready, write it in `next_thought`."
  @leave_empty "When the final answer is ready, write it in `next_thought`, and leave `tool_calls` empty."

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)

  defp lm(native?, replies) do
    owner = self()
    counter = :counters.new(1, [])

    handler = fn messages, opts ->
      :counters.add(counter, 1, 1)
      send(owner, {:request, messages, opts})
      Enum.at(replies, :counters.get(counter, 1) - 1)
    end

    if native?, do: Imp.LM.Static.new(handler: handler), else: %TextOnlyLM{handler: handler}
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp text(messages), do: Enum.map_join(messages, "\n", &to_string(&1.content))

  defp assert_native({messages, opts}, guidance) do
    assert Enum.map(opts[:tools], & &1.function.name) == ["look"]
    refute text(messages) =~ "tool_calls"
    assert hd(messages).content =~ guidance
    refute hd(messages).content =~ "plain text"
  end

  defp assert_text_only({messages, opts}, marker) do
    assert opts[:tools] in [nil, []]
    refute Keyword.has_key?(opts, :tool_choice)
    assert hd(messages).content =~ marker
    assert hd(messages).content =~ @leave_empty
  end

  # A stored turn that carries only the task's answer, and a step demo that
  # made a call.
  defp history,
    do:
      Imp.History.new([
        %{"intent" => "earlier", "answer" => "earlier reply"},
        %{"intent" => "later", "next_thought" => "noted", "tool_calls" => []}
      ])

  defp demo,
    do:
      Imp.example(%{
        intent: "d?",
        next_thought: "I will look",
        tool_calls: [%{"name" => "look", "arguments" => %{}}]
      })

  defp agent(adapter, lm) do
    agent = Imp.react("intent -> answer", [look()], lm: lm, adapter: adapter)
    %{agent | react: %{agent.react | demos: [demo()]}}
  end

  defp run(agent) do
    assert {:ok, prediction} = Imp.call(agent, %{intent: "what?", history: history()})
    assert Imp.get(prediction, :answer) == "done."
    assert prediction.metadata.termination_reason == :answered
    requests()
  end

  describe "an LM that calls tools natively" do
    test "Chat: the answer goes in next_thought, and plain text is still read as it" do
      [request] = run(agent(Imp.Adapter.Chat, lm(true, ["done."])))
      assert_native(request, @in_field)
    end

    test "JSON: the answer goes in next_thought" do
      [request] = run(agent(Imp.Adapter.JSON, lm(true, [~s({"next_thought": "done."})])))
      assert_native(request, @in_field)
    end

    test "XML: the answer goes in next_thought" do
      [request] =
        run(agent(Imp.Adapter.XML, lm(true, ["<next_thought>\ndone.\n</next_thought>"])))

      assert_native(request, @in_field)
    end

    test "the JSON fallback of a Chat step" do
      replies = ["[[ ## tool_calls ## ]]\nnot a list", ~s({"next_thought": "done."})]
      [first, fallback] = run(agent(Imp.Adapter.Chat, lm(true, replies)))
      assert_native(first, @in_field)
      assert_native(fallback, @in_field)
    end

    test "the JSON fallback of a step with submit" do
      replies = [
        "[[ ## tool_calls ## ]]\nnot a list",
        %{tool_calls: [%{name: "submit", arguments: %{answer: "done.", confidence: 1.0}}]}
      ]

      agent = Imp.react("intent -> answer, confidence: float", [look()], lm: lm(true, replies))
      assert {:ok, prediction} = Imp.call(agent, %{intent: "what?"})
      assert Imp.get(prediction, :answer) == "done."

      assert [_first, _fallback] = sent = requests()

      for {messages, opts} <- sent do
        assert Enum.map(opts[:tools], & &1.function.name) == ["look", "submit"]
        refute text(messages) =~ "tool_calls"
      end
    end

    test "a stored answer is replayed as the answer, and a demo shows no calls" do
      [{messages, _opts}] = run(agent(Imp.Adapter.Chat, lm(true, ["done."])))
      assistant = messages |> Enum.filter(&(&1.role == :assistant)) |> Enum.map(& &1.content)

      assert "earlier reply" in assistant
      assert "noted" in assistant
      assert "[[ ## next_thought ## ]]\nI will look\n\n[[ ## completed ## ]]\n" in assistant
      refute text(messages) =~ "Not supplied"
    end
  end

  describe "an LM that cannot call tools" do
    test "Chat" do
      [request] =
        run(
          agent(
            Imp.Adapter.Chat,
            lm(false, ["[[ ## next_thought ## ]]\ndone.\n\n[[ ## tool_calls ## ]]\n[]"])
          )
        )

      assert_text_only(request, "[[ ## tool_calls ## ]]")
    end

    test "JSON" do
      [request] =
        run(agent(Imp.Adapter.JSON, lm(false, [~s({"next_thought": "done.", "tool_calls": []})])))

      assert_text_only(request, ~s("tool_calls"))
    end

    test "XML" do
      reply = "<next_thought>\ndone.\n</next_thought>\n<tool_calls>\n[]\n</tool_calls>"
      [request] = run(agent(Imp.Adapter.XML, lm(false, [reply])))
      assert_text_only(request, "<tool_calls>")
    end

    test "the JSON fallback of a Chat step" do
      replies = [
        "[[ ## tool_calls ## ]]\nnot a list",
        ~s({"next_thought": "done.", "tool_calls": []})
      ]

      [first, fallback] = run(agent(Imp.Adapter.Chat, lm(false, replies)))
      assert_text_only(first, "[[ ## tool_calls ## ]]")
      assert_text_only(fallback, ~s("tool_calls"))
    end

    test "a demo shows its calls in the field the model writes" do
      [{messages, _opts}] = run(agent(Imp.Adapter.Chat, lm(false, ["done."])))
      assert text(messages) =~ ~s([[ ## tool_calls ## ]]\n[{"arguments": {}, "name": "look"}])
    end
  end

  # PlanFirst adds a `plan` output to what it formats; only the tool-calls
  # output is left out, so the plan it asks for is still described.
  test "PlanFirst keeps its plan described" do
    agent =
      Imp.react("intent -> answer", [look()],
        lm: lm(true, ["done."]),
        adapter: Imp.Adapter.PlanFirst
      )

    assert {:ok, _prediction} = Imp.call(agent, %{intent: "what?"})
    [{[system | _], _opts}] = requests()
    assert system.content =~ "`plan`"
    refute system.content =~ "tool_calls"
  end

  # After a tool call every input is in the history, so a JSON or XML request
  # has nothing left to ask but its output requirements: they are a user
  # message of their own, never text appended to the tool result.
  for {adapter, reply, requirements} <- [
        {Imp.Adapter.JSON, ~s({"next_thought": "done."}),
         "Respond with a JSON object in the following order of fields: `next_thought`."},
        {Imp.Adapter.XML, "<next_thought>\ndone.\n</next_thought>",
         "Respond with the corresponding output fields wrapped in XML tags `<next_thought>`."}
      ] do
    test "#{inspect(adapter)} ends a later step on its output requirements" do
      call = %{next_thought: "Look.", tool_calls: [%{id: "c1", name: "look", arguments: %{}}]}

      agent =
        Imp.react("intent -> answer", [look()],
          lm: lm(true, [call, unquote(reply)]),
          adapter: unquote(adapter)
        )

      assert {:ok, prediction} = Imp.call(agent, %{intent: "what?"})
      assert Imp.get(prediction, :answer) == "done."

      [_first, {messages, _opts}] = requests()
      assert Enum.at(messages, -2).role == :tool
      assert Enum.at(messages, -2).content == ~s({"seen": [1]})
      assert List.last(messages) == %{role: :user, content: unquote(requirements)}
    end
  end

  # A host's output renderer shapes XML's stored turns too, and one that
  # builds on the default gets XML's.
  test "XML uses a host's output renderer" do
    for {renderer, expected} <- [
          {fn _signature, outputs, _missing -> "SAID " <> outputs.answer end, "SAID Madrid"},
          {fn signature, outputs, missing, opts ->
             "SAID " <> opts[:default_outputs].(signature, outputs, missing)
           end, "SAID <answer>\nMadrid\n</answer>"}
        ] do
      program =
        Imp.predict("question -> answer",
          lm: lm(true, ["<answer>\nParis\n</answer>"]),
          adapter: Imp.Adapter.XML,
          adapter_opts: [output_renderer: renderer],
          demos: [%{question: "Capital of Spain?", answer: "Madrid"}]
        )

      assert {:ok, _prediction} = Imp.call(program, %{question: "Capital of France?"})
      [{messages, _opts}] = requests()
      assert Enum.find(messages, &(&1.role == :assistant)).content == expected
    end
  end
end
