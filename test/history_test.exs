defmodule DSEx.HistoryTest do
  use ExUnit.Case

  alias DSEx.Adapters.Types

  test "builds immutable signature-shaped history through the public facade" do
    history =
      DSEx.history()
      |> DSEx.append_history(%{question: "What is the capital of France?", answer: "Paris"})
      |> DSEx.append_history(question: "What is the capital of Germany?", answer: "Berlin")

    assert %DSEx.History{} = history

    assert DSEx.History.messages(history) == [
             %{question: "What is the capital of France?", answer: "Paris"},
             %{question: "What is the capital of Germany?", answer: "Berlin"}
           ]
  end

  test "chat adapter renders history turns before the current input" do
    signature = DSEx.signature("question, history -> answer")

    history =
      DSEx.history([
        %{question: "What is the capital of France?", answer: "Paris"},
        %{question: "What is the capital of Germany?", answer: "Berlin"}
      ])

    messages =
      DSEx.Adapter.Chat.format(signature, %{question: "What about Italy?", history: history}, [])

    assert [
             %{role: :system},
             %{role: :user, content: prior_user_1},
             %{role: :assistant, content: prior_assistant_1},
             %{role: :user, content: prior_user_2},
             %{role: :assistant, content: prior_assistant_2},
             %{role: :user, content: current_user}
           ] = messages

    assert prior_user_1 == "[[ ## question ## ]]\nWhat is the capital of France?"
    assert prior_assistant_1 == "[[ ## answer ## ]]\nParis"
    assert prior_user_2 == "[[ ## question ## ]]\nWhat is the capital of Germany?"
    assert prior_assistant_2 == "[[ ## answer ## ]]\nBerlin"
    assert current_user =~ "[[ ## question ## ]]\nWhat about Italy?"
    refute current_user =~ "[[ ## history ## ]]"
    refute current_user =~ "%DSEx.History"
  end

  test "history input does not collide with ordinary non-history fields named history" do
    signature = DSEx.signature("question, history -> answer")

    [%{role: :system}, %{role: :user, content: current_user}] =
      DSEx.Adapter.Chat.format(
        signature,
        %{question: "Next?", history: [%{tool: :lookup, result: "Paris"}]},
        []
      )

    assert current_user =~ "[[ ## history ## ]]"
    assert current_user =~ "lookup"
  end

  test "history redaction preserves structure while hiding secrets" do
    history =
      DSEx.history([
        %{question: "Use sk-test-secret-1234567890?", answer: "No", api_key: "sk-live-secret"}
      ])

    redacted = DSEx.History.redact(history)

    assert DSEx.History.messages(redacted) == [
             %{question: "[REDACTED]", answer: "No", api_key: "[REDACTED]"}
           ]
  end

  test "history dump and load are JSON-safe" do
    history = DSEx.history([%{question: "Q?", answer: "A"}])

    restored =
      history
      |> DSEx.History.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> DSEx.History.load()

    assert restored == history
  end

  test "program saving stores program shape, not runtime history input" do
    program = DSEx.predict("question, history -> answer", lm: DSEx.LM.Static)

    dumped = DSEx.Saving.dump(program)

    assert dumped["type"] == "predict"
    refute inspect(dumped) =~ "What is the capital of France?"
  end

  test "streaming collect composes with history-aware predict programs" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          assert Enum.any?(messages, &(&1.role == :assistant and &1.content =~ "Paris"))
          "[[ ## answer ## ]]\nRome\n[[ ## completed ## ]]"
        end
      ]
    }

    program = DSEx.predict("question, history -> answer", lm: lm)
    history = DSEx.history([%{question: "Capital of France?", answer: "Paris"}])

    assert DSEx.Streaming.collect(program, %{question: "Capital of Italy?", history: history}) ==
             "Rome"
  end

  test "provider chat history remains explicit adapter-type history" do
    assert [
             %{role: "user", content: [%{type: "text", text: "hello"}]}
           ] = Types.to_openai(%Types.History{messages: [%{role: :user, content: "hello"}]})

    assert_raise ArgumentError,
                 ~r/provider chat messages use DSEx\.Adapters\.Types\.History/,
                 fn -> Types.to_openai(DSEx.history([%{question: "Q?", answer: "A"}])) end
  end
end
