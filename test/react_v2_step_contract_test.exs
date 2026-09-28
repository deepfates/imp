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
    refute text(messages) =~ "whose description is"
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

  # An LM that cannot call tools reads them from the prompt, as DSPy renders a
  # list of tools: every tool's description and arguments, `submit`'s too.
  test "a step for an LM that cannot call tools lists every tool" do
    search =
      Imp.tool(:search, "Search the catalog by SKU and region", fn _ -> "ok" end,
        schema: %{
          "type" => "object",
          "properties" => %{
            "sku" => %{"type" => "string", "description" => "exact SKU"},
            "region" => %{"type" => "string", "enum" => ["eu", "us"]}
          },
          "required" => ["sku", "region"]
        }
      )

    agent =
      Imp.react("intent -> answer, confidence: float", [search],
        lm: lm(false, ["just prose, no call"]),
        max_iters: 1
      )

    assert {:ok, _prediction} = Imp.call(agent, %{intent: "find SKU 12"})

    for {messages, opts} <- requests() do
      assert opts[:tools] in [nil, []]
      listing = List.last(messages).content

      for piece <- [
            "search, whose description is <desc>Search the catalog by SKU and region</desc>.",
            "exact SKU",
            "sku",
            "region",
            "submit, whose description is <desc>Submit the final outputs for the task.</desc>.",
            "answer",
            "confidence"
          ] do
        assert listing =~ piece
      end
    end
  end

  # On the wire, a request that declares no tools carries no tool blocks: its
  # earlier steps are text, as DSPy replays them without native calling.
  test "a ReqLLM step for a model without tool calling sends no tool blocks" do
    owner = self()
    counter = :counters.new(1, [])

    replies = [
      "[[ ## next_thought ## ]]\nLook.\n\n[[ ## tool_calls ## ]]\n" <>
        ~s([{"name": "look", "arguments": {}}]) <> "\n\n[[ ## completed ## ]]",
      "It holds 1."
    ]

    adapter = fn request ->
      :counters.add(counter, 1, 1)
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(owner, {:body, body})

      response = %{
        "id" => "msg_#{:counters.get(counter, 1)}",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-x",
        "content" => [
          %{"type" => "text", "text" => Enum.at(replies, :counters.get(counter, 1) - 1)}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(response)
       )}
    end

    # The registry lists this model with tool calling; the client says it has
    # none. Every step follows the client, which is read once, when it is built.
    model = %{provider: :anthropic, id: "claude-x", capabilities: %{tools: %{enabled: true}}}

    lm =
      Imp.req_llm(model,
        api_key: "local-test-key",
        cache: false,
        max_retries: 0,
        req_http_options: [adapter: adapter, retry: false, max_retries: 0]
      )

    lm = %{lm | tool_calling: false}

    assert {:ok, prediction} =
             Imp.call(Imp.react("intent -> answer", [look()], lm: lm), %{intent: "hi"})

    assert Imp.get(prediction, :answer) == "It holds 1."

    assert_received {:body, first}
    assert_received {:body, second}

    for body <- [first, second] do
      refute Map.has_key?(body, "tools")

      for message <- body["messages"], block <- List.wrap(message["content"]), is_map(block) do
        refute block["type"] in ["tool_use", "tool_result"]
      end
    end

    assert Enum.any?(second["messages"], fn message ->
             message |> Jason.encode!() |> String.contains?("tool_call_results")
           end)
  end

  # A tool with a required argument, an optional one with a default, and a
  # `$ref`, its properties in the order they were declared.
  test "the listing shows each tool's whole argument schema" do
    properties =
      Jason.OrderedObject.new([
        {"sku", %{"type" => "string", "description" => "exact SKU"}},
        {"region", %{"type" => "string", "enum" => ["eu", "us"]}},
        {"limit", %{"type" => "integer", "default" => 5}},
        {"ref", %{"$ref" => "#/$defs/Ref"}}
      ])

    schema = %{
      "type" => "object",
      "properties" => properties,
      "required" => ["sku", "region"],
      "$defs" => %{
        "Ref" => %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
      }
    }

    search = Imp.tool(:search, "Search the catalog", fn _ -> "ok" end, schema: schema)
    agent = Imp.react("intent -> answer", [search], lm: lm(false, ["done."]))
    assert {:ok, _} = Imp.call(agent, %{intent: "find"})
    [{messages, _opts}] = requests()
    listing = List.last(messages).content

    expected =
      ~s(search, whose description is <desc>Search the catalog</desc>. It takes arguments ) <>
        ~s({"properties":{"sku":{"description":"exact SKU","type":"string"},) <>
        ~s("region":{"enum":["eu","us"],"type":"string"},"limit":{"default":5,"type":"integer"},) <>
        ~s("ref":{"$ref":"#/$defs/Ref"}},"required":["sku","region"],) <>
        ~s("$defs":{"Ref":{"properties":{"id":{"type":"string"}},"type":"object"}}}.)

    assert listing =~ Jason.encode!(expected)
  end

  # A model that writes its calls is shown the shape `tool_calls` reads.
  test "a step for an LM that cannot call tools shows how to write a call" do
    [{[system | _], _opts}] = run(agent(Imp.Adapter.Chat, lm(false, ["done."])))

    assert system.content =~
             "2. `tool_calls` (list): The tools to call, as a JSON list in which each call has " <>
               "`name` and `arguments`. Example: " <>
               ~s([{"name": "search", "arguments": {"query": "cats"}}])
  end
end
