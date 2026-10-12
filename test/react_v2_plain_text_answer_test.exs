defmodule ReActV2PlainTextAnswerTest do
  use ExUnit.Case, async: true

  # A ReActV2 program built with `finish: :text` has no `submit`: with an LM
  # that calls tools natively, the message the model writes without
  # a tool call is the answer. The system message says only that. It shows no
  # `[[ ## answer ## ]]` or `[[ ## completed ## ]]` marker to write, which
  # would be a second, different way to finish, and it lists no output field:
  # the answer is the message, so a field name would be a label with no place
  # to go, and models wrote it into the message ahead of their reply.

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)

  defp lm(reply, native? \\ true) do
    owner = self()

    handler = fn messages, _opts ->
      send(owner, {:messages, messages})
      reply
    end

    if native?, do: Imp.LM.Static.new(handler: handler), else: %TextOnlyLM{handler: handler}
  end

  defp system_message do
    assert_received {:messages, [%{role: :system, content: content} | _rest]}
    content
  end

  test "the system message of a native one-text-output step, exactly" do
    program = Imp.react("intent -> answer", [look()], finish: :text, lm: lm("ok"))
    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})

    assert system_message() ==
             "Your input fields are:\n" <>
               "1. `intent` (string):\n" <>
               "Inputs will be structured in the following way, with the appropriate values filled in.\n" <>
               "\n" <>
               "[[ ## intent ## ]]\n" <>
               "{intent}\n" <>
               "\n" <>
               "In adhering to this structure, your objective is: \n" <>
               "        Given the fields `intent`, produce the fields `answer`.\n" <>
               "        You are an Agent. Use the supplied tools to gather information and take actions.\n" <>
               "        Call tools when more information is needed.\n" <>
               "        When the final answer is ready, reply without calling a tool.\n" <>
               "        The available tools are: `look`."
  end

  test "the answer's description is said once, with the message it describes, and its name not at all" do
    signature =
      Imp.signature(
        %{
          inputs: [%{name: :intent, desc: "What happened."}],
          outputs: [%{name: :answer, desc: "What you say back: all of your last message."}]
        },
        "Be brief."
      )

    program = Imp.react(signature, [look()], finish: :text, lm: lm("ok"))
    assert {:ok, _prediction} = Imp.call(program, %{intent: "hello"})
    system = system_message()

    assert system =~
             "        When the final answer is ready, reply without calling a tool. " <>
               "What you say back: all of your last message.\n"

    assert length(String.split(system, "What you say back")) == 2
    refute system =~ "`answer`"
    refute system =~ "output fields"
    refute system =~ "outputs to produce"
  end

  test "a host sets the agent line through adapter options, or omits it" do
    custom =
      Imp.react("intent -> answer", [look()],
        finish: :text,
        lm: lm("ok"),
        adapter_opts: [agent_line: "Help the user."]
      )

    assert {:ok, _prediction} = Imp.call(custom, %{intent: "hello"})
    system = system_message()

    assert system =~
             "`answer`.\n        Help the user.\n        Call tools when more information is needed."

    refute system =~ "You are an Agent"

    omitted =
      Imp.react("intent -> answer", [look()],
        finish: :text,
        lm: lm("ok"),
        adapter_opts: [agent_line: nil]
      )

    assert {:ok, _prediction} = Imp.call(omitted, %{intent: "hello"})
    assert system_message() =~ "`answer`.\n        Call tools when more information is needed."
  end

  test "a final message with no markers is the answer" do
    program = Imp.react("intent -> answer", [look()], finish: :text, lm: lm("It is a cat."))
    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert Imp.get(prediction, :answer) == "It is a cat."
    assert prediction.metadata.termination_reason == :answered
  end

  test "a reply that still writes the old markers is read as before" do
    reply = "[[ ## answer ## ]]\nIt is a cat.\n\n[[ ## completed ## ]]\n"
    program = Imp.react("intent -> answer", [look()], finish: :text, lm: lm(reply))
    assert {:ok, prediction} = Imp.call(program, %{intent: "what is it?"})
    assert Imp.get(prediction, :answer) == "It is a cat."
  end

  test "an LM that writes its tool calls still gets the marker template" do
    reply = "[[ ## answer ## ]]\nIt is a cat.\n\n[[ ## tool_calls ## ]]\n[]"
    program = Imp.react("intent -> answer", [look()], finish: :text, lm: lm(reply, false))
    assert {:ok, _prediction} = Imp.call(program, %{intent: "what is it?"})
    system = system_message()

    assert system =~ "[[ ## answer ## ]]\n{answer}"
    assert system =~ "[[ ## completed ## ]]"
    assert system =~ "write it in `answer`, and leave `tool_calls` empty."
  end

  test "a signature with submit still gets the marker template" do
    reply = %{tool_calls: [%{name: "submit", arguments: %{answer: "cat", confidence: 1.0}}]}
    program = Imp.react("intent -> answer, confidence: float", [look()], lm: lm(reply))
    assert {:ok, _prediction} = Imp.call(program, %{intent: "what is it?"})
    system = system_message()

    assert system =~ "[[ ## completed ## ]]"
    assert system =~ "When the final answer is ready, call `submit` with `answer`, `confidence`."
  end
end
