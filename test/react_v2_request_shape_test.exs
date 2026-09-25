defmodule ReActV2RequestShapeTest do
  use ExUnit.Case, async: true

  # What a provider's prompt cache is keyed on: each step's request must be the
  # previous step's request plus the newest exchange, with the tool roster sent
  # once, natively, and never rendered as text after the history.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1, 2, 3]} end)

  defp recording_lm(owner, steps) do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn messages, opts ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)
        send(owner, {:request, n, messages, opts})

        if n < steps,
          do: %{
            next_thought: "look #{n}",
            tool_calls: [%{id: "c#{n}", name: "look", arguments: %{}}]
          },
          else: "ok"
      end
    )
  end

  defp requests(n), do: for(i <- 1..n, do: receive(do: ({:request, ^i, m, o} -> {m, o})))

  defp render(m),
    do: {m[:role], m[:content], m[:tool_calls]}

  test "each step's request is the previous request plus the newest exchange" do
    program = Imp.react_v2("intent -> answer", [look()], lm: recording_lm(self(), 3))
    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"

    [{r1, _}, {r2, _}, {r3, _}] = requests(3)

    # Remove `response_instruction: false` or reinstate the `tools` input field
    # in ReActV2.new/3: the first user message changes between steps 1 and 2.
    assert Enum.map(r1, &render/1) == Enum.take(Enum.map(r2, &render/1), length(r1))
    assert Enum.map(r2, &render/1) == Enum.take(Enum.map(r3, &render/1), length(r2))
    assert length(r2) == length(r1) + 2
    assert length(r3) == length(r2) + 2
  end

  test "the roster goes to the provider once, natively, and never as text" do
    program = Imp.react_v2("intent -> answer", [look()], lm: recording_lm(self(), 2))
    assert {:ok, _} = Imp.call(program, %{intent: "hello"})

    for {messages, opts} <- requests(2) do
      assert Enum.map(opts[:tools], & &1.function.name) == ["look"]
      refute Enum.any?(messages, &(&1[:content] =~ "[[ ## tools ## ]]"))

      refute Enum.any?(
               messages,
               &(&1[:content] =~ "Respond with the corresponding output fields")
             )
    end
  end

  test "the loop's guidance is adapter data, said by the default system renderer" do
    program = Imp.react_v2("intent -> answer", [look()], lm: recording_lm(self(), 1))
    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    [{[system | _], _}] = requests(1)

    assert system.role == :system

    assert system.content =~
             "When the final answer is ready, write it as plain text without calling a tool."

    assert system.content =~ "The available tools are: `look`."
    refute system.content =~ "submit"
    # And the program's own instructions carry none of it.
    refute program.signature.instructions =~ "You are an Agent"
  end

  # With `submit`, the guidance is DSPy ReActV2's text.
  test "a signature with submit is told to call it, in DSPy's words" do
    submit_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(self(), {:system, hd(messages)})
          %{tool_calls: [%{name: "submit", arguments: %{answer: "ok", confidence: 1.0}}]}
        end
      )

    program = Imp.react_v2("intent -> answer, confidence: float", [look()], lm: submit_lm)
    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    assert_received {:system, system}

    for line <- [
          "You are an Agent. Use the supplied tools to produce `answer`, `confidence` from `intent`.",
          "Call tools when more information is needed.",
          "When the final answer is ready, call `submit` with `answer`, `confidence`.",
          "The available tools are: `look`, `submit`."
        ] do
      assert system.content =~ line
    end
  end

  # Without this list an output's description reached the model only inside
  # `submit`'s parameter schema, which a model reads when it calls `submit`,
  # not while it decides which tools to call.
  test "every step says what each output means, with its type and description" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:system, hd(messages)})
          %{tool_calls: [%{name: "submit", arguments: %{team: "atlas", confidence: 1.0}}]}
        end
      )

    signature =
      Imp.Signature.new(%{
        instructions: "Route the ticket.",
        inputs: [%{name: :ticket, desc: "A customer's support ticket"}],
        outputs: [
          %{
            name: :team,
            type: :string,
            constraints: %{enum: ["atlas", "harbor"]},
            desc: "atlas owns money; harbor owns outages"
          },
          %{name: :confidence, type: :float, desc: "From 0 to 1"}
        ]
      })

    program = Imp.react_v2(signature, [look()], lm: lm)
    assert {:ok, _} = Imp.call(program, %{ticket: "We were charged twice."})
    assert_received {:system, system}

    assert system.content =~
             "The outputs to produce are:\n" <>
               "        1. `team` (one of: atlas, harbor): atlas owns money; harbor owns outages\n" <>
               "        2. `confidence` (number): From 0 to 1\n" <>
               "        Call tools when more information is needed."
  end

  test "a host can replace the system message and keep parsing" do
    owner = self()

    # The renderer sees the loop's working signature; the program's own
    # outputs come with the guidance.
    renderer = fn _signature, opts ->
      send(owner, {:rendered, opts[:guidance]})
      "You are Gregory. Outputs: #{Enum.join(opts[:guidance].output_names, ", ")}."
    end

    program =
      Imp.react_v2("intent -> answer", [look()],
        lm: recording_lm(self(), 2),
        adapter_opts: [system_renderer: renderer]
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"

    assert_received {:rendered,
                     %{
                       finish_tool: nil,
                       output_names: [:answer],
                       tool_names: [:look]
                     }}

    [{[system | _], _} | _] = requests(2)
    assert system.content == "You are Gregory. Outputs: answer."
  end
end
