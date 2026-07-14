defmodule ReActV2Test do
  use ExUnit.Case, async: true

  test "executes parallel calls, preserves IDs and results, and submits final outputs" do
    parent = self()
    lookup = DSEx.tool(:lookup, "lookup", fn %{query: query} -> "found #{query}" end)

    lm =
      action_lm(
        [
          %{
            next_thought: "gather and finish",
            tool_calls: [
              %{id: "lookup-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "missing-1", name: "missing", arguments: %{}},
              %{id: "submit-1", name: "submit", arguments: %{answer: "BEAM"}}
            ]
          }
        ],
        parent
      )

    assert {:ok, prediction} =
             DSEx.react_v2("question -> answer", [lookup], lm: lm)
             |> DSEx.call(%{question: "What runtime?"})

    assert DSEx.get(prediction, :answer) == "BEAM"
    assert DSEx.get(prediction, :termination_reason) == :submit
    assert %DSEx.History{messages: [event]} = DSEx.get(prediction, :history)
    assert Enum.map(event.tool_calls.tool_calls, & &1.id) == ["lookup-1", "missing-1", "submit-1"]

    assert [lookup_result, missing_result, submit_result] = event.tool_call_results
    assert lookup_result.result == "found beam"
    assert missing_result.error
    assert match?({:error, {:unknown_tool, "missing"}}, missing_result.result)
    refute submit_result.error
    assert_received {:lm_call, _opts}
  end

  test "unknown and failing tools remain history observations instead of aborting the loop" do
    broken = DSEx.tool(:broken, "broken", fn _args -> raise "boom" end)

    lm =
      action_lm([
        %{tool_calls: [%{name: "broken", arguments: %{}}, %{name: "unknown", arguments: %{}}]},
        %{tool_calls: [%{name: "submit", arguments: %{answer: "recovered"}}]}
      ])

    assert {:ok, prediction} =
             DSEx.react_v2("question -> answer", [broken], lm: lm, max_iters: 2)
             |> DSEx.call(%{question: "recover"})

    assert DSEx.get(prediction, :answer) == "recovered"
    assert %DSEx.History{messages: [first, _second]} = DSEx.get(prediction, :history)
    assert Enum.all?(first.tool_call_results, & &1.error)
  end

  test "forces submit after empty calls and marks forced termination" do
    parent = self()

    lm =
      action_lm(
        [
          %{next_thought: "ready", tool_calls: []},
          %{tool_calls: [%{name: "submit", arguments: %{answer: "forced"}}]}
        ],
        parent
      )

    assert {:ok, prediction} =
             DSEx.react_v2("question -> answer", [], lm: lm)
             |> DSEx.call(%{question: "answer"})

    assert DSEx.get(prediction, :answer) == "forced"
    assert DSEx.get(prediction, :termination_reason) == :forced_submit
    assert_received {:lm_call, _normal_opts}
    assert_received {:lm_call, forced_opts}
    assert get_in(Map.new(forced_opts), [:tool_choice, :function, :name]) == "submit"
    assert Keyword.has_key?(forced_opts, :reasoning_effort)
    assert Keyword.get(forced_opts, :reasoning_effort) == nil
  end

  test "accepts atom and string per-call max_iters overrides" do
    for max_iters_key <- [:max_iters, "max_iters"] do
      parent = self()

      lm =
        action_lm(
          [
            %{tool_calls: [%{name: "lookup", arguments: %{}}]},
            %{tool_calls: [%{name: "submit", arguments: %{answer: "forced"}}]}
          ],
          parent
        )

      lookup = DSEx.tool(:lookup, "lookup", fn _arguments -> "observed" end)
      program = DSEx.react_v2("question -> answer", [lookup], lm: lm, max_iters: 5)

      assert {:ok, prediction} =
               DSEx.call(program, Map.put(%{question: "q"}, max_iters_key, 1))

      assert DSEx.get(prediction, :answer) == "forced"
      assert DSEx.get(prediction, :termination_reason) == :forced_submit
      assert_received {:lm_call, _normal_opts}
      assert_received {:lm_call, _forced_opts}
      refute_received {:lm_call, _extra_opts}
    end
  end

  test "strictly validates per-call max_iters before calling the model" do
    parent = self()
    lm = action_lm([], parent)
    program = DSEx.react_v2("question -> answer", [], lm: lm)

    for invalid <- [-1, 1.0, "1", nil] do
      assert {:error, {:invalid_react_v2_max_iters, ^invalid}} =
               DSEx.call(program, %{"max_iters" => invalid, question: "q"})
    end

    refute_received {:lm_call, _opts}
  end

  test "records malformed submit as an error result and returns an inspectable incomplete prediction" do
    lm =
      action_lm([
        %{tool_calls: [%{name: "submit", arguments: %{}}]},
        %{tool_calls: []}
      ])

    assert {:ok, prediction} =
             DSEx.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> DSEx.call(%{question: "q"})

    assert DSEx.get(prediction, :answer) == nil
    assert DSEx.get(prediction, :termination_reason) == :max_iters
    assert %DSEx.History{messages: [event]} = DSEx.get(prediction, :history)

    assert [%{error: true, result: {:error, {:missing_output_fields, [:answer]}}}] =
             event.tool_call_results
  end

  test "accepts serialized history and reserves submit" do
    assert_raise ArgumentError, ~r/submit is reserved/, fn ->
      submit = DSEx.tool(:submit, "not allowed", & &1)
      DSEx.react_v2("question -> answer", [submit])
    end

    history = %{"messages" => [%{"question" => "prior", "answer" => "prior answer"}]}
    lm = action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "continued"}}]}])

    assert {:ok, prediction} =
             DSEx.react_v2("question -> answer", [], lm: lm, max_iters: 0)
             |> DSEx.call(%{question: "next", history: history})

    assert DSEx.get(prediction, :answer) == "continued"
    assert %DSEx.History{messages: [prior, current]} = DSEx.get(prediction, :history)
    assert prior.question == "prior"
    assert current.answer == "continued"
  end

  test "chat adapter replays structured history as native assistant and tool messages" do
    program = DSEx.react_v2("question -> answer", [])

    history =
      DSEx.History.new([
        %{
          question: "prior",
          next_thought: "checking",
          tool_calls:
            DSEx.Adapters.Types.ToolCalls.new([
              %{id: "call-1", name: "lookup", arguments: %{query: "beam"}}
            ]),
          tool_call_results: [
            %{id: "call-1", name: "lookup", result: "BEAM", error: false}
          ]
        }
      ])

    messages =
      DSEx.Adapter.Chat.format(program.react.signature, %{history: history, tools: []}, [])

    assert [
             %{role: :system},
             %{role: :user, content: user_content},
             %{role: :assistant, content: "checking", tool_calls: [call]},
             %{role: :tool, content: "BEAM", tool_calls: [%{id: "call-1"}]},
             %{role: :user}
           ] = messages

    assert user_content =~ "prior"
    assert call.id == "call-1"
    assert call.name == "lookup"
  end

  test "participates in LM demo and registry-backed persistence lifecycle" do
    runner = fn %{query: query} -> query end
    registry = DSEx.Saving.Registry.new(lookup_runner: runner)
    tool = DSEx.tool(:lookup, "lookup", runner)
    demo = DSEx.example(question: "demo", answer: "demo") |> DSEx.with_inputs(:question)

    program =
      DSEx.react_v2("question -> answer", [tool])
      |> DSEx.with_demos([demo])
      |> DSEx.dump(registry: registry)
      |> DSEx.load(registry: registry)
      |> DSEx.with_lm(action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "ok"}}]}]))

    assert program.react.demos == [demo]
    assert {:ok, prediction} = DSEx.call(program, %{question: "q"})
    assert DSEx.get(prediction, :answer) == "ok"
  end

  defp action_lm(actions, notify \\ nil) do
    {:ok, state} = Agent.start_link(fn -> actions end)

    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          if notify, do: send(notify, {:lm_call, opts})

          Agent.get_and_update(state, fn
            [action | rest] -> {action, rest}
            [] -> {%{tool_calls: []}, []}
          end)
        end
      ]
    }
  end
end
