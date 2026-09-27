defmodule PredictJSONFallbackRequestTest do
  use ExUnit.Case, async: true

  # A Chat or XML reply that cannot be parsed is retried through the JSON
  # adapter. That retry is the same request in the other format: the program's
  # renderers, loop guidance and demos go with it, and telemetry names the
  # adapter whose reply failed and the one that retried it.

  defp scripted_lm(owner, replies) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(owner, {:request, n, messages, opts})
        Enum.at(replies, n - 1)
      end
    )
  end

  defp request(n), do: receive(do: ({:request, ^n, messages, _opts} -> messages))

  test "the fallback request carries the program's system renderer and demos" do
    renderer = fn signature, _opts ->
      "CUSTOM SYSTEM for #{Enum.map_join(signature.outputs, ", ", & &1.name)}"
    end

    program =
      Imp.predict("question -> answer",
        lm: scripted_lm(self(), ["no markers here", ~s({"answer": "Paris"})]),
        adapter: Imp.Adapter.Chat,
        adapter_opts: [system_renderer: renderer],
        demos: [%{question: "Capital of Spain?", answer: "Madrid"}]
      )

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"

    [first_system | first_rest] = request(1)
    [fallback_system | fallback_rest] = request(2)

    assert first_system.content == "CUSTOM SYSTEM for answer"
    assert fallback_system.content == "CUSTOM SYSTEM for answer"

    # The demo is in both, in each request's own format.
    assert Enum.any?(first_rest, &(&1.content =~ "Madrid"))
    assert Enum.any?(fallback_rest, &(&1.role == :assistant and &1.content =~ ~s("Madrid")))
    assert List.last(fallback_rest).content =~ "Respond with a JSON object"
  end

  test "an n > 1 fallback carries the system renderer too" do
    owner = self()
    counter = :counters.new(1, [])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          :counters.add(counter, 1, 1)
          send(owner, {:system, hd(messages).content})
          if :counters.get(counter, 1) <= 2, do: "no markers", else: ~s({"answer": "ok"})
        end
      )

    program =
      Imp.predict("question -> answer",
        lm: lm,
        adapter: Imp.Adapter.Chat,
        adapter_opts: [system_renderer: fn _signature, _opts -> "CUSTOM SYSTEM" end],
        config: [n: 2]
      )

    assert {:ok, _prediction} = Imp.call(program, %{question: "Q?"})

    for _completion <- 1..4, do: assert_received({:system, "CUSTOM SYSTEM"})
  end

  # The unparseable reply comes on the second step, after a tool call, when
  # every input is already in the history and the request has nothing left
  # to ask but the JSON output requirements.
  test "a ReActV2 step whose reply cannot be parsed falls back with the loop guidance" do
    look = Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)

    lm =
      scripted_lm(self(), [
        %{next_thought: "Look first.", tool_calls: [%{id: "c1", name: "look", arguments: %{}}]},
        "[[ ## tool_calls ## ]]\nnot a list of calls",
        ~s({"next_thought": "It holds 1.", "tool_calls": []})
      ])

    program = Imp.react("intent -> answer", [look], lm: lm)
    assert {:ok, prediction} = Imp.call(program, %{intent: "what is in it?"})
    assert Imp.get(prediction, :answer) == "It holds 1."

    _first = request(1)
    step = request(2)
    [fallback_system | fallback_rest] = request(3)

    for line <- [
          "You are an Agent. Use the supplied tools to produce `answer` from `intent`.",
          "When the final answer is ready, write it as plain text without calling a tool.",
          "The available tools are: `look`."
        ] do
      assert fallback_system.content =~ line
    end

    # The same history, then the requirements as their own user message; the
    # tool result is not rewritten to carry them.
    assert Enum.drop(fallback_rest, -1) == tl(step)
    assert List.last(fallback_rest) == %{role: :user, content: json_requirements()}
  end

  defp json_requirements,
    do:
      "Respond with a JSON object in the following order of fields: `next_thought`, " <>
        "then `tool_calls` (must be formatted as a list)."

  test "the fallback request renders stored turns with the program's output renderer" do
    program =
      Imp.predict("question -> answer",
        lm: scripted_lm(self(), ["no markers here", ~s({"answer": "Paris"})]),
        adapter: Imp.Adapter.Chat,
        adapter_opts: [
          output_renderer: fn _signature, demo, _missing -> "SAID " <> demo.answer end
        ],
        demos: [%{question: "Capital of Spain?", answer: "Madrid"}]
      )

    assert {:ok, _prediction} = Imp.call(program, %{question: "Capital of France?"})

    for n <- [1, 2] do
      assert Enum.any?(request(n), &(&1.role == :assistant and &1.content == "SAID Madrid"))
    end
  end

  test "a host's renderers reach a ReActV2 step's fallback" do
    look = Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)

    lm =
      scripted_lm(self(), [
        "[[ ## tool_calls ## ]]\nnot a list of calls",
        ~s({"next_thought": "It holds 1.", "tool_calls": []})
      ])

    program =
      Imp.react("intent -> answer", [look],
        lm: lm,
        adapter_opts: [system_renderer: fn _signature, _opts -> "You are Gregory." end]
      )

    assert {:ok, _prediction} = Imp.call(program, %{intent: "what is in it?"})
    assert [%{role: :system, content: "You are Gregory."} | _] = request(1)
    assert [%{role: :system, content: "You are Gregory."} | _] = request(2)
  end

  test "telemetry names the adapter whose reply failed and the fallback adapter" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :adapter, :parse, :json_fallback]])

    for {adapter, input} <- [{Imp.Adapter.Chat, "chat_probe"}, {Imp.Adapter.XML, "xml_probe"}] do
      # A signature no other test uses, so events from concurrent tests are
      # told apart from this one's.
      signature = Imp.signature("fallback_#{input} -> answer")

      program =
        Imp.predict(signature,
          lm: scripted_lm(self(), ["no markers here", ~s({"answer": "ok"})]),
          adapter: adapter
        )

      assert {:ok, _prediction} = Imp.call(program, %{"fallback_#{input}" => "x"})
      spec = Imp.Signature.to_spec(signature)

      assert_received {^ref, [:imp, :adapter, :parse, :json_fallback], %{count: 1},
                       %{signature: ^spec} = metadata}

      assert metadata.adapter == adapter
      assert metadata.fallback_adapter == Imp.Adapter.JSON
    end
  end
end
