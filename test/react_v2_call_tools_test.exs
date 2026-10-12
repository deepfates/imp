defmodule ReActV2CallToolsTest do
  use ExUnit.Case, async: true

  # A call can give the runners of the program's tools for that call, as it can
  # its own `max_iters`, `last_request_note` and `config`. The tools the model
  # is shown -- names, descriptions, schemas -- stay the program's, so the
  # request is the same; only what a call to them does is the call's own. A
  # host that keeps per-call state (what a call has done so far, for whom it
  # runs) gives each call its own runners, and copies of one program value
  # called at once never share that state.

  @signature "question -> answer"
  @schema %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}

  defp lookup(run), do: Imp.tool(:lookup, "Look something up.", run, schema: @schema)

  # Calls `lookup` once, then answers with the result it read.
  defp lm(owner) do
    Imp.LM.Static.new(
      handler: fn messages, opts ->
        send(owner, {:tools_sent, opts[:tools]})

        case List.last(messages) do
          %{role: :tool, content: result} -> result
          _ -> %{tool_calls: [%{id: "l", name: "lookup", arguments: %{"q" => "x"}}]}
        end
      end
    )
  end

  test "a call's runners are used for that call only, and the request is unchanged" do
    program = Imp.react(@signature, [lookup(fn _ -> "from the program" end)], lm: lm(self()))

    assert {:ok, prediction} =
             Imp.call(program, %{question: "hi", tools: [lookup(fn _ -> "from the call" end)]})

    assert Imp.get(prediction, :answer) == "from the call"
    assert_received {:tools_sent, sent_with_call}

    assert {:ok, prediction} = Imp.call(program, %{question: "hi"})
    assert Imp.get(prediction, :answer) == "from the program"
    assert_received {:tools_sent, sent_without}
    assert sent_with_call == sent_without
  end

  test "a tool the model would be shown differently is refused before any request" do
    program = Imp.react(@signature, [lookup(fn _ -> "x" end)], lm: lm(self()))

    renamed = Imp.tool(:search, "Look something up.", fn _ -> "y" end, schema: @schema)
    reworded = Imp.tool(:lookup, "Find it.", fn _ -> "y" end, schema: @schema)
    reshaped = Imp.tool(:lookup, "Look something up.", fn _ -> "y" end, schema: %{})

    for tool <- [renamed, reworded, reshaped] do
      assert {:error, {:invalid_react_v2_tools, message}} =
               Imp.call(program, %{question: "hi", tools: [tool]})

      assert message =~ to_string(tool.name)
    end

    assert {:error, {:invalid_react_v2_tools, _}} =
             Imp.call(program, %{question: "hi", tools: :lookup})

    refute_received {:tools_sent, _}
  end

  test "the program value is unchanged, so an optimizer's copy keeps its runners" do
    program = Imp.react(@signature, [lookup(fn _ -> "from the program" end)], lm: lm(self()))
    before = program.tools

    assert {:ok, _} =
             Imp.call(program, %{question: "hi", tools: [lookup(fn _ -> "from the call" end)]})

    assert program.tools == before
  end
end
