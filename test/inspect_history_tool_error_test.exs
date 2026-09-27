defmodule InspectHistoryToolErrorTest do
  use ExUnit.Case, async: true

  # A ReActV2 history keeps each tool result as the term the tool returned,
  # so a tool error is an `{:error, reason}` tuple, which JSON cannot encode.

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1, 2, 3]} end)

  defp lm do
    counter = :counters.new(1, [])

    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 ->
            %{
              next_thought: "finish",
              tool_calls: [%{id: "c1", name: "submit", arguments: %{answer: "ok"}}]
            }

          _ ->
            "ok"
        end
      end
    )
  end

  test "inspect_history renders a ReActV2 history whose model called an unknown tool" do
    program = Imp.react("question -> answer", [look()], lm: lm())
    assert {:ok, prediction} = Imp.call(program, %{question: "hello"})
    history = prediction.metadata.history

    assert inspect(history) =~ "unknown_tool"

    rendered = Imp.inspect_history(history)

    assert rendered =~ "Turn 1"
    assert rendered =~ "unknown_tool"
    assert rendered =~ "submit"
  end

  test "inspect_history renders terms JSON has no encoding for" do
    history =
      Imp.history([
        %{question: "q", answer: "a", result: {:error, :timeout}, owner: self(), ref: make_ref()},
        %{question: "q2", answer: "a2", scores: %{{:step, 1} => 0.5}}
      ])

    rendered = Imp.inspect_history(history)

    assert rendered =~ "Turn 2"
    assert rendered =~ "timeout"
    assert rendered =~ "#PID<"
    assert rendered =~ "#Reference<"
  end
end
