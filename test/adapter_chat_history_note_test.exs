defmodule Imp.Adapter.ChatHistoryNoteTest do
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat

  # A host sometimes has to say something *about* a stored turn in the next
  # request: what became true after that turn ended, which no re-rendering of
  # the turn itself can carry. `:history_note_renderer` is that seam. It is
  # consulted for every stored turn, native tool turns included, and its text
  # is one user message right behind that turn's own messages.

  defp signature do
    %Imp.Signature{
      inputs: [
        Imp.Signature.Field.new(%{name: :question}, :input),
        Imp.Signature.Field.new(%{name: :history, type: :history}, :input)
      ],
      outputs: [Imp.Signature.Field.new(%{name: :answer}, :output)]
    }
  end

  defp history do
    Imp.History.new([
      %{
        question: "post it",
        next_thought: "posting",
        tool_calls:
          Imp.Adapter.Types.ToolCalls.new([
            %{id: "call-1", name: "post", arguments: %{text: "hello"}}
          ])
          |> Imp.Redaction.redact(),
        tool_call_results: [%{id: "call-1", name: "post", result: "posted", error: false}]
      },
      %{question: "and then?", answer: "nothing else"}
    ])
  end

  defp render(note_renderer) do
    Chat.format(signature(), %{history: history(), question: "now what?"},
      history_note_renderer: note_renderer
    )
  end

  test "a note is a user message immediately after the turn it is about" do
    messages =
      render(fn _signature, turn ->
        if Map.get(turn, :question) == "post it",
          do: "The post was not delivered: the account's allowance was exhausted."
      end)

    # The system message, then the first turn, its note, then the second turn.
    assert [
             %{role: :system},
             %{role: :user, content: first_inputs},
             %{role: :assistant, tool_calls: [%{id: "call-1"}]},
             %{role: :tool, content: "posted"},
             %{role: :user, content: note},
             %{role: :user, content: second_inputs},
             %{role: :assistant, content: second_outputs},
             %{role: :user}
           ] = messages

    assert first_inputs =~ "post it"
    assert note == "The post was not delivered: the account's allowance was exhausted."
    assert second_inputs =~ "and then?"
    assert second_outputs =~ "nothing else"
  end

  test "a renderer that returns nothing adds nothing, for either kind of turn" do
    for note <- [fn _signature, _turn -> nil end, fn _signature, _turn -> "" end] do
      assert Enum.map(render(note), & &1.role) ==
               [:system, :user, :assistant, :tool, :user, :assistant, :user]
    end

    # And with no renderer at all, the message sequence is what it always was.
    assert Chat.format(signature(), %{history: history(), question: "now what?"}, [])
           |> Enum.map(& &1.role) ==
             [:system, :user, :assistant, :tool, :user, :assistant, :user]
  end

  test "a note reaches a plain history turn too" do
    messages = render(fn _signature, turn -> "note for #{Map.get(turn, :question)}" end)

    notes =
      messages
      |> Enum.filter(&(&1.role == :user and to_string(&1.content) =~ "note for "))
      |> Enum.map(& &1.content)

    assert notes == ["note for post it", "note for and then?"]
  end
end
