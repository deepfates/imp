defmodule Imp.HistoryTest do
  use ExUnit.Case

  alias Imp.Adapter.Types

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
                 ~r/provider chat messages use Imp\.Adapter\.Types\.History/,
                 fn -> Types.to_openai(Imp.history([%{question: "Q?", answer: "A"}])) end
  end

  test "history retains unknown symbolic names without weakening strict report decoding" do
    typed = Imp.history([%{result: {:error, %{reason: :refused, retry: false}}, answer: 7}])
    assert typed |> Imp.History.dump() |> Imp.History.load() == typed
    name = "retired_history_symbol_#{System.unique_integer([:positive])}"
    tag = %{"__imp_type__" => "atom", "value" => name}
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert_raise ArgumentError, fn -> Imp.Optimizer.Report.decode_term(tag) end
    state = %{"messages" => [%{"result" => tag}]}
    assert [%{result: ^name}] = Imp.History.load(state) |> Imp.History.messages()
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    dumped = Imp.History.load(state) |> Imp.History.dump()
    assert [%{result: ^name}] = Imp.Optimizer.Report.decode_term(dumped["messages"])

    collision = %{"__imp_type__" => "map", "entries" => [[tag, 1], [name, 2]]}

    assert_raise ArgumentError, ~r/duplicate decoded key/, fn ->
      Imp.History.load(%{"messages" => [%{"result" => collision}]})
    end

    assert_raise ArgumentError, fn ->
      Imp.History.load(%{"messages" => [%{"result" => Map.put(tag, "extra", true)}]})
    end
  end

  @tag :tmp_dir
  test "cold restart continues a real ReAct history after its capability disappears", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "history.json")
    args = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    writer = """
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    lm = Imp.LM.Static.new(handler: fn _, _ ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})
      if n == 0 do
        %{tool_calls: [%{id: "old-call", name: "retired_fetch", arguments: %{}}]}
      else
        %{tool_calls: [%{id: "done", name: "submit", arguments: %{answer: "earlier answer"}}]}
      end
    end)
    tool = Imp.tool(:retired_fetch, "retired capability", fn _ ->
      {:error, {:history_retired_capability_failure, %{outcome: "unknown"}}}
    end)
    program = Imp.react_v2("intent -> answer", [tool], lm: lm)
    {:ok, result} = Imp.call(program, %{intent: "earlier question"})
    File.write!(#{inspect(path)}, result |> Imp.get(:history) |> Imp.History.dump() |> Jason.encode!())
    """

    assert {_, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", writer],
               stderr_to_stdout: true
             )

    # The old tool and error atom are absent from this fresh VM. A string literal
    # checks the symbol without accidentally interning it in the test itself.
    reader = """
    name = "history_retired_capability_failure"
    absent = fn ->
      try do
        String.to_existing_atom(name)
        raise "retired symbol was interned"
      rescue
        ArgumentError -> :ok
      end
    end
    absent.()
    history = File.read!(#{inspect(path)}) |> Jason.decode!() |> Imp.History.load()
    absent.()
    lm = Imp.LM.Static.new(handler: fn messages, _ ->
      unless Enum.any?(messages, fn m ->
        m.role == :tool and String.contains?(m.content, name) and String.contains?(m.content, "unknown")
      end), do: raise("old tool observation missing from next turn")
      unless Enum.any?(messages, &(Map.get(&1, :content, "") =~ "earlier question")),
        do: raise("old intent missing")
      %{tool_calls: [%{id: "new-done", name: "submit", arguments: %{answer: "continued"}}]}
    end)
    program = Imp.react_v2("intent -> answer", [], lm: lm)
    {:ok, result} = Imp.call(program, %{intent: "continue", history: history})
    "continued" = Imp.get(result, :answer)
    absent.()
    IO.puts("continued without retired capability")
    """

    assert {output, 0} =
             System.cmd(System.find_executable("elixir"), args ++ ["-e", reader],
               stderr_to_stdout: true
             )

    assert output =~ "continued without retired capability"
  end
end
