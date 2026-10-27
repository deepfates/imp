defmodule ReActV2RequestShapeTest do
  use ExUnit.Case, async: true

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

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
            answer: "look #{n}",
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
    program = Imp.react("intent -> answer", [look()], lm: recording_lm(self(), 3))
    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"

    [{r1, _}, {r2, _}, {r3, _}] = requests(3)

    # Remove `response_instruction: false`, or render the `tools` input for a
    # native step: the first user message changes between steps 1 and 2.
    assert Enum.map(r1, &render/1) == Enum.take(Enum.map(r2, &render/1), length(r1))
    assert Enum.map(r2, &render/1) == Enum.take(Enum.map(r3, &render/1), length(r2))
    assert length(r2) == length(r1) + 2
    assert length(r3) == length(r2) + 2
  end

  test "the roster goes to the provider once, natively, and never as text" do
    program = Imp.react("intent -> answer", [look()], lm: recording_lm(self(), 2))
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
    program = Imp.react("intent -> answer", [look()], lm: recording_lm(self(), 1))
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

  defp submitting_lm(owner, arguments) do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        send(owner, {:messages, messages})
        %{tool_calls: [%{name: "submit", arguments: arguments}]}
      end
    )
  end

  defp routing_signature do
    Imp.Signature.new(%{
      instructions: "Route the ticket.\n  Keep it short.",
      inputs: [
        %{name: :ticket, desc: "A customer's support ticket"},
        %{name: :priority, desc: "How urgent it is"}
      ],
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
  end

  # With native tool calls and `submit`, nothing is parsed from the text the
  # model writes, so the system message says what is true in plain words and
  # leaves out DSPy's reply template, which models read as a benchmark
  # harness. Every step says what each output means, with its type and
  # description: otherwise an output's description reaches the model only
  # inside `submit`'s parameter schema.
  test "a native loop with submit is told the task, the message parts, how to finish and the tools" do
    lm = submitting_lm(self(), %{team: "atlas", confidence: 1.0})
    program = Imp.react(routing_signature(), [look()], lm: lm)
    assert {:ok, _} = Imp.call(program, %{ticket: "We were charged twice."})
    assert_received {:messages, [system, user]}

    assert system.content ==
             """
             Route the ticket.
             Keep it short.

             Each message to you has these parts, each under its heading, such as [[ ## ticket ## ]]. A part that doesn't apply to a message is left out.
             1. `ticket` (string): A customer's support ticket
             2. `priority` (string): How urgent it is

             Use the tools to read and to act, as many times as you need. Text you write is not sent. It stays in this conversation as your own note.

             To finish, call `submit` with `team` and `confidence`:
             1. `team` (one of: atlas, harbor): atlas owns money; harbor owns outages
             2. `confidence` (number): From 0 to 1

             The tools you have: `look`, `submit`.\
             """

    for scaffold <- [
          "Your input fields are",
          "Your output fields are",
          "next_thought",
          "{ticket}",
          "[[ ## completed ## ]]",
          "In adhering to this structure",
          "You are an Agent"
        ] do
      refute system.content =~ scaffold
    end

    # A part with no value is left out, as the system message says.
    assert user.content == "[[ ## ticket ## ]]\nWe were charged twice."
  end

  test "a host's agent line follows the instructions, and nil leaves it out" do
    lm = submitting_lm(self(), %{answer: 1})

    program =
      Imp.react("intent -> answer: int", [look()],
        lm: lm,
        adapter_opts: [agent_line: "You keep the town's lamps."]
      )

    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    assert_received {:messages, [system | _]}

    assert system.content =~
             "Given the fields `intent`, produce the fields `answer`.\n\n" <>
               "You keep the town's lamps.\n\nEach message to you has these parts"

    program =
      Imp.react("intent -> answer: int", [look()], lm: lm, adapter_opts: [agent_line: nil])

    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    assert_received {:messages, [system | _]}

    assert system.content =~
             "Given the fields `intent`, produce the fields `answer`.\n\nEach message to you has"

    assert system.content =~ "To finish, call `submit` with `answer`:\n1. `answer` (integer):"
  end

  # Written tool calls are parsed from the reply's markers, so that loop keeps
  # DSPy's layout and its words.
  test "a loop whose model writes its tool calls keeps DSPy's layout" do
    owner = self()

    lm = %TextOnlyLM{
      handler: fn messages, _opts ->
        send(owner, {:messages, messages})

        "[[ ## next_thought ## ]]\nDone.\n\n[[ ## tool_calls ## ]]\n" <>
          ~s([{"name": "submit", "arguments": {"answer": "ok", "confidence": 1.0}}]) <>
          "\n\n[[ ## completed ## ]]"
      end
    }

    program = Imp.react("intent -> answer, confidence: float", [look()], lm: lm)
    assert {:ok, _} = Imp.call(program, %{intent: "hello"})
    assert_received {:messages, [system | _]}

    for line <- [
          "Your input fields are:",
          "[[ ## tool_calls ## ]]",
          "In adhering to this structure, your objective is: ",
          "You are an Agent. Use the supplied tools to produce `answer`, `confidence` from `intent`.",
          "Call tools when more information is needed.",
          "When the final answer is ready, call `submit` with `answer`, `confidence`.",
          "The available tools are: `look`, `submit`."
        ] do
      assert system.content =~ line
    end
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
      Imp.react("intent -> answer", [look()],
        lm: recording_lm(self(), 2),
        adapter_opts: [system_renderer: renderer]
      )

    assert {:ok, prediction} = Imp.call(program, %{intent: "hello"})
    assert Imp.get(prediction, :answer) == "ok"

    assert_received {:rendered,
                     %{
                       submit_tool: nil,
                       output_names: [:answer],
                       tool_names: [:look]
                     }}

    [{[system | _], _} | _] = requests(2)
    assert system.content == "You are Gregory. Outputs: answer."
  end

  test "a step answered in prose returns that prose" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> "The thing holds 1, 2 and 3.\n\nThat is all." end
      )

    program = Imp.react("intent -> answer", [look()], lm: lm)
    assert {:ok, prediction} = Imp.call(program, %{intent: "what is in it?"})
    assert Imp.get(prediction, :answer) == "The thing holds 1, 2 and 3.\n\nThat is all."
    assert prediction.metadata.termination_reason == :answered
  end

  test "tool calling is the LM's to declare" do
    refute Imp.LM.tool_calling_capability(%TextOnlyLM{})
    assert Imp.LM.tool_calling_capability(Imp.LM.Static.new())
    refute Imp.LM.tool_calling_capability(%Imp.Clients.TRLLM{})

    no_tools = %{provider: :openai, id: "m", capabilities: %{tools: %{enabled: false}}}
    tools = %{provider: :openai, id: "m", capabilities: %{tools: %{enabled: true}}}
    silent = %{provider: :openai, id: "m", capabilities: %{}}

    refute Imp.LM.tool_calling_capability(%Imp.Clients.ReqLLM{model: no_tools})
    assert Imp.LM.tool_calling_capability(%Imp.Clients.ReqLLM{model: tools})
    assert Imp.LM.tool_calling_capability(%Imp.Clients.ReqLLM{model: silent})
  end
end
