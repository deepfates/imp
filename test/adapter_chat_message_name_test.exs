defmodule Imp.Adapter.ChatMessageNameTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Imp.Adapter.Chat

  # A turn's `:user_name` and `:assistant_name`, and the request's
  # `:user_name`, name those messages (the OpenAI chat format's participant
  # `name`). They are metadata, never rendered as fields.

  defp signature(extra_inputs \\ []) do
    %Imp.Signature{
      inputs:
        [
          Imp.Signature.Field.new(%{name: :question}, :input),
          Imp.Signature.Field.new(%{name: :history, type: :history}, :input)
        ] ++ Enum.map(extra_inputs, &Imp.Signature.Field.new(%{name: &1}, :input)),
      outputs: [Imp.Signature.Field.new(%{name: :answer}, :output)]
    }
  end

  test "a named history turn names its user and assistant messages" do
    history =
      Imp.History.new([
        %{question: "Who won?", answer: "Blue.", user_name: "alice", assistant_name: "imp"},
        %{"question" => "By how much?", "answer" => "Two.", "user_name" => "bob"},
        %{question: "Anyone else?", answer: "No."}
      ])

    messages =
      Chat.format(signature(), %{history: history, question: "Rematch?", user_name: "carol"}, [])

    assert [
             %{role: :system} = system,
             %{role: :user, name: "alice", content: first},
             %{role: :assistant, name: "imp"},
             %{role: :user, name: "bob"},
             %{role: :assistant} = bob_reply,
             %{role: :user} = unnamed,
             %{role: :assistant} = unnamed_reply,
             %{role: :user, name: "carol", content: request}
           ] = messages

    refute Map.has_key?(system, :name)
    refute Map.has_key?(bob_reply, :name)
    refute Map.has_key?(unnamed, :name)
    refute Map.has_key?(unnamed_reply, :name)
    refute first =~ "alice"
    refute request =~ "carol"
  end

  test "a native tool turn names its user and assistant messages, not its tool results" do
    history =
      Imp.History.new([
        %{
          question: "post it",
          user_name: "alice",
          assistant_name: "imp",
          next_thought: "posting",
          tool_calls:
            Imp.Adapter.Types.ToolCalls.new([
              %{id: "call-1", name: "post", arguments: %{text: "hello"}}
            ]),
          tool_call_results: [%{id: "call-1", name: "post", result: "posted", error: false}]
        }
      ])

    messages = Chat.format(signature(), %{history: history, question: "next"}, [])

    assert [
             %{role: :system},
             %{role: :user, name: "alice"},
             %{role: :assistant, name: "imp", tool_calls: [_]},
             %{role: :tool} = tool,
             %{role: :user} = request
           ] = messages

    refute Map.has_key?(tool, :name)
    refute Map.has_key?(request, :name)
  end

  test "a signature field called user_name stays a field" do
    messages =
      Chat.format(signature([:user_name]), %{question: "hi", user_name: "alice"}, [])

    assert %{role: :user, content: content} = request = List.last(messages)
    refute Map.has_key?(request, :name)
    assert content =~ "alice"
  end

  test "Imp.Predict passes the request's user_name without an extra-input warning" do
    test_pid = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(test_pid, {:messages, messages})
          %{answer: "hello"}
        end
      )

    program = Imp.predict("question -> answer", lm: lm)

    log =
      capture_log(fn ->
        assert {:ok, prediction} = Imp.call(program, %{question: "hi", user_name: "alice"})
        assert Imp.get(prediction, :answer) == "hello"
      end)

    refute log =~ "not in signature"
    assert_received {:messages, [%{role: :system}, %{role: :user, name: "alice"}]}
  end
end
