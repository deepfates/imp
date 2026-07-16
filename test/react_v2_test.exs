defmodule ReActV2Test do
  use ExUnit.Case, async: true

  defmodule NativeToolStub do
    def generate_text(model, messages, opts) do
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:native_tool_request, opts})

      response =
        Agent.get_and_update(state, fn
          :initial ->
            {%ReqLLM.Response{
               id: "resp_empty",
               model: to_string(model),
               context: ReqLLM.Context.new(messages),
               message: ReqLLM.Context.assistant(""),
               object: %{tool_calls: []},
               finish_reason: :stop
             }, :forced}

          :forced ->
            {%ReqLLM.Response{
               id: "resp_submit",
               model: to_string(model),
               context: ReqLLM.Context.new(messages),
               message:
                 ReqLLM.Context.assistant("",
                   tool_calls: [
                     ReqLLM.ToolCall.new("toolu_submit", "submit", ~s({"answer":"Paris"}))
                   ]
                 ),
               object: nil,
               finish_reason: :tool_calls
             }, :done}
        end)

      {:ok, response}
    end
  end

  test "executes parallel calls, preserves IDs and results, and submits final outputs" do
    parent = self()
    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found #{query}" end)

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
             Imp.react_v2("question -> answer", [lookup], lm: lm)
             |> Imp.call(%{question: "What runtime?"})

    assert Imp.get(prediction, :answer) == "BEAM"
    assert Imp.get(prediction, :termination_reason) == :submit
    assert %Imp.History{messages: [event]} = Imp.get(prediction, :history)
    assert Enum.map(event.tool_calls.tool_calls, & &1.id) == ["lookup-1", "missing-1", "submit-1"]

    assert [lookup_result, missing_result, submit_result] = event.tool_call_results
    assert lookup_result.result == "found beam"
    assert missing_result.error
    assert match?({:error, {:unknown_tool, "missing"}}, missing_result.result)
    refute submit_result.error
    assert_received {:lm_call, _opts}
  end

  test "unknown and failing tools remain history observations instead of aborting the loop" do
    broken = Imp.tool(:broken, "broken", fn _args -> raise "boom" end)

    lm =
      action_lm([
        %{tool_calls: [%{name: "broken", arguments: %{}}, %{name: "unknown", arguments: %{}}]},
        %{tool_calls: [%{name: "submit", arguments: %{answer: "recovered"}}]}
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [broken], lm: lm, max_iters: 2)
             |> Imp.call(%{question: "recover"})

    assert Imp.get(prediction, :answer) == "recovered"
    assert %Imp.History{messages: [first, _second]} = Imp.get(prediction, :history)
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
             Imp.react_v2("question -> answer", [], lm: lm)
             |> Imp.call(%{question: "answer"})

    assert Imp.get(prediction, :answer) == "forced"
    assert Imp.get(prediction, :termination_reason) == :forced_submit
    assert_received {:lm_call, _normal_opts}
    assert_received {:lm_call, forced_opts}
    assert Keyword.fetch!(forced_opts, :tool_choice) == %{type: "tool", name: "submit"}
    assert Keyword.has_key?(forced_opts, :reasoning_effort)
    assert Keyword.get(forced_opts, :reasoning_effort) == nil
  end

  test "forces native submit through the provider-neutral ReqLLM tool choice" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("anthropic:fixture",
        req_module: NativeToolStub,
        state: state,
        test_pid: self(),
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :forced_submit

    assert_received {:native_tool_request, initial_opts}
    assert initial_opts[:tool_choice] == "auto"
    assert_received {:native_tool_request, forced_opts}
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}
  end

  test "normalizes atom- and string-keyed tool-call collection wrappers" do
    for wrapped <- [
          %{tool_calls: [%{name: "submit", arguments: %{answer: "atom"}}]},
          %{"tool_calls" => [%{"name" => "submit", "arguments" => %{"answer" => "string"}}]}
        ] do
      lm = action_lm([Imp.Prediction.new(%{tool_calls: wrapped})])

      assert {:ok, prediction} =
               Imp.react_v2("question -> answer", [], lm: lm)
               |> Imp.call(%{question: "q"})

      assert Imp.get(prediction, :answer) in ["atom", "string"]
      assert [event] = Imp.get(prediction, :history).messages

      assert [%{id: "call_0_0", name: "submit"}] = event.tool_calls.tool_calls
    end
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

      lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "observed" end)
      program = Imp.react_v2("question -> answer", [lookup], lm: lm, max_iters: 5)

      assert {:ok, prediction} =
               Imp.call(program, Map.put(%{question: "q"}, max_iters_key, 1))

      assert Imp.get(prediction, :answer) == "forced"
      assert Imp.get(prediction, :termination_reason) == :forced_submit
      assert_received {:lm_call, _normal_opts}
      assert_received {:lm_call, _forced_opts}
      refute_received {:lm_call, _extra_opts}
    end
  end

  test "strictly validates per-call max_iters before calling the model" do
    parent = self()
    lm = action_lm([], parent)
    program = Imp.react_v2("question -> answer", [], lm: lm)

    for invalid <- [-1, 1.0, "1", nil] do
      assert {:error, {:invalid_react_v2_max_iters, ^invalid}} =
               Imp.call(program, %{"max_iters" => invalid, question: "q"})
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
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "q"})

    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :max_iters
    assert %Imp.History{messages: [event]} = Imp.get(prediction, :history)

    assert [%{error: true, result: {:error, {:missing_output_fields, [:answer]}}}] =
             event.tool_call_results
  end

  test "accepts serialized history and reserves submit" do
    assert_raise ArgumentError, ~r/submit is reserved/, fn ->
      submit = Imp.tool(:submit, "not allowed", & &1)
      Imp.react_v2("question -> answer", [submit])
    end

    history = %{"messages" => [%{"question" => "prior", "answer" => "prior answer"}]}
    lm = action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "continued"}}]}])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 0)
             |> Imp.call(%{question: "next", history: history})

    assert Imp.get(prediction, :answer) == "continued"
    assert %Imp.History{messages: [prior, current]} = Imp.get(prediction, :history)
    assert prior.question == "prior"
    assert current.answer == "continued"
  end

  test "chat adapter replays structured history as native assistant and tool messages" do
    program = Imp.react_v2("question -> answer", [])

    history =
      Imp.History.new([
        %{
          question: "prior",
          next_thought: "checking",
          tool_calls:
            Imp.Adapters.Types.ToolCalls.new([
              %{id: "call-1", name: "lookup", arguments: %{query: "beam"}}
            ])
            |> Imp.Redaction.redact(),
          tool_call_results: [
            %{id: "call-1", name: "lookup", result: "BEAM", error: false}
          ]
        }
      ])

    messages =
      Imp.Adapter.Chat.format(program.react.signature, %{history: history, tools: []}, [])

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
    registry = Imp.Saving.Registry.new(lookup_runner: runner)
    tool = Imp.tool(:lookup, "lookup", runner)
    demo = Imp.example(question: "demo", answer: "demo") |> Imp.with_inputs(:question)

    program =
      Imp.react_v2("question -> answer", [tool])
      |> Imp.with_demos([demo])
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)
      |> Imp.with_lm(action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "ok"}}]}]))

    assert program.react.demos == [demo]
    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "ok"
  end

  defp action_lm(actions, notify \\ nil) do
    {:ok, state} = Agent.start_link(fn -> actions end)

    %{
      module: Imp.LM.Static,
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
