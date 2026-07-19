defmodule Imp.HistoryTest do
  use ExUnit.Case

  alias Imp.Adapters.Types

  test "builds immutable signature-shaped history through the public facade" do
    history =
      Imp.history()
      |> Imp.append_history(%{question: "What is the capital of France?", answer: "Paris"})
      |> Imp.append_history(question: "What is the capital of Germany?", answer: "Berlin")

    assert %Imp.History{} = history

    assert Imp.History.messages(history) == [
             %{question: "What is the capital of France?", answer: "Paris"},
             %{question: "What is the capital of Germany?", answer: "Berlin"}
           ]
  end

  test "chat adapter renders history turns before the current input" do
    signature = Imp.signature("question, history -> answer")

    history =
      Imp.history([
        %{question: "What is the capital of France?", answer: "Paris"},
        %{question: "What is the capital of Germany?", answer: "Berlin"}
      ])

    messages =
      Imp.Adapter.Chat.format(signature, %{question: "What about Italy?", history: history}, [])

    assert [
             %{role: :system},
             %{role: :user, content: prior_user_1},
             %{role: :assistant, content: prior_assistant_1},
             %{role: :user, content: prior_user_2},
             %{role: :assistant, content: prior_assistant_2},
             %{role: :user, content: current_user}
           ] = messages

    assert prior_user_1 == "[[ ## question ## ]]\nWhat is the capital of France?"
    # History assistant turns carry the trailing `[[ ## completed ## ]]` marker,
    # matching DSPy format_assistant_message_content (dee-u4st axis A): the same
    # renderer serves demos and conversation history, and DSPy always appends it.
    assert prior_assistant_1 == "[[ ## answer ## ]]\nParis\n\n[[ ## completed ## ]]\n"
    assert prior_user_2 == "[[ ## question ## ]]\nWhat is the capital of Germany?"
    assert prior_assistant_2 == "[[ ## answer ## ]]\nBerlin\n\n[[ ## completed ## ]]\n"
    assert current_user =~ "[[ ## question ## ]]\nWhat about Italy?"
    refute current_user =~ "[[ ## history ## ]]"
    refute current_user =~ "%Imp.History"
  end

  test "history input does not collide with ordinary non-history fields named history" do
    signature = Imp.signature("question, history -> answer")

    [%{role: :system}, %{role: :user, content: current_user}] =
      Imp.Adapter.Chat.format(
        signature,
        %{question: "Next?", history: [%{tool: :lookup, result: "Paris"}]},
        []
      )

    assert current_user =~ "[[ ## history ## ]]"
    assert current_user =~ "lookup"
  end

  test "history redaction preserves structure while hiding secrets" do
    history =
      Imp.history([
        %{question: "Use sk-test-secret-1234567890?", answer: "No", api_key: "sk-live-secret"}
      ])

    redacted = Imp.History.redact(history)

    assert Imp.History.messages(redacted) == [
             %{question: "[REDACTED]", answer: "No", api_key: "[REDACTED]"}
           ]
  end

  test "history dump and load are JSON-safe" do
    history = Imp.history([%{question: "Q?", answer: "A"}])

    restored =
      history
      |> Imp.History.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.History.load()

    assert restored == history
  end

  test "program saving stores program shape, not runtime history input" do
    # No pinned LM: the program is never called here, and a Static-pinned
    # program can no longer be dumped (dee-i3s4 / P03 made that loud).
    program = Imp.predict("question, history -> answer")

    dumped = Imp.Saving.dump(program)

    assert dumped["type"] == "predict"
    refute inspect(dumped) =~ "What is the capital of France?"
  end

  test "streaming collect composes with history-aware predict programs" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "Paris"))
          "[[ ## answer ## ]]\nRome\n[[ ## completed ## ]]"
        end
      ]
    }

    program = Imp.predict("question, history -> answer", lm: lm)
    history = Imp.history([%{question: "Capital of France?", answer: "Paris"}])

    assert Imp.Streaming.collect(program, %{question: "Capital of Italy?", history: history}) ==
             "Rome"
  end

  test "provider chat history remains explicit adapter-type history" do
    assert [
             %{role: "user", content: [%{type: "text", text: "hello"}]}
           ] = Types.to_openai(%Types.History{messages: [%{role: :user, content: "hello"}]})

    assert_raise ArgumentError,
                 ~r/provider chat messages use Imp\.Adapters\.Types\.History/,
                 fn -> Types.to_openai(Imp.history([%{question: "Q?", answer: "A"}])) end
  end
end
