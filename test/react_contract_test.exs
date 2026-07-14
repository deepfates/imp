defmodule ReActContractTest do
  use ExUnit.Case, async: true

  test "submit must provide required signature outputs" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{extra: "only"}}]}
        end
      ]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:missing_output_fields, [:answer]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "empty tool calls cannot bypass required output validation" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: []}
        end
      ]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:missing_output_fields, [:answer]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "max iteration exhaustion is an error with trace history" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "observed"}]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "zero max_iters fails before calling the model" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :react_lm_called)
          %{tool_calls: []}
        end
      ]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 0)

    assert {:error, {:react_max_iters, []}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})

    refute_received :react_lm_called
  end

  test "invocation-local max_iters overrides the constructor budget without reaching the LM inputs" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:react_messages, messages})
          %{tool_calls: [%{name: :lookup, arguments: %{}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 4)

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "observed"}]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q", max_iters: 1})

    assert_receive {:react_messages, messages}
    refute inspect(messages) =~ "max_iters"
    refute_received {:react_messages, _messages}
  end

  test "invocation-local max_iters is validated before calling the model" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> send(parent, :react_lm_called) end]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm)

    assert {:error, {:invalid_react_max_iters, "1"}} =
             DSEx.Predict.ReAct.call(agent, %{"max_iters" => "1", question: "q"})

    refute_received :react_lm_called
  end

  test "constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/DSEx\.Predict\.ReAct\.new\/3: expected keyword options/, fn ->
      DSEx.Predict.ReAct.new("question -> answer", [], %{lm: nil})
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.ReAct\.new\/3 expects tools to be a list of DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.ReAct.new("question -> answer", :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.ReAct\.new\/3 expects tools to be a list of DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.ReAct.new("question -> answer", [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.ReAct\.new\/3: invalid value for :max_iters option: expected non negative integer/,
                 fn ->
                   DSEx.Predict.ReAct.new("question -> answer", [], max_iters: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.ReAct\.new\/3: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   DSEx.Predict.ReAct.new("question -> answer", [], tool_policy: %{only: :lookup})
                 end

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: nil)

    assert {:error, {:invalid_react_inputs, message}} =
             DSEx.Predict.ReAct.call(agent, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_react_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.Predict.ReAct.call(agent, [:not_a_pair])
  end

  test "tool policy denial stops ReAct before executing LM-selected tool" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "secret"}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> raise "should not run" end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, tool_policy: [])

    assert {:error, {:tool_denied, :lookup}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "unknown LM-selected tools fail immediately instead of spinning to max iterations" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: "external_tool", arguments: %{query: "x"}}]}
        end
      ]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 3)

    assert {:error, {:unknown_tool, "external_tool"}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "malformed provider tool calls become structured ReAct errors" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: ["not-a-tool-call"]}
        end
      ]
    }

    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:malformed_tool_call, "not-a-tool-call"}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "provider JSON string tool arguments are decoded before execution" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: ~s({"query":"capital"})}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> %{answer: "Paris"} end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:error,
            {:react_max_iters,
             [%{tool: :lookup, arguments: %{query: "capital"}, result: %{answer: "Paris"}}]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "OpenAI-style nested function tool calls are normalized before execution" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{
                id: "call_lookup",
                type: "function",
                function: %{
                  name: "lookup",
                  arguments: ~s({"query":"capital"})
                }
              },
              %{
                id: "call_submit",
                type: "function",
                function: %{
                  name: "submit",
                  arguments: ~s({"answer":"Paris"})
                }
              }
            ]
          }
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> "Paris" end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"

    assert [
             %{tool: :lookup, arguments: %{query: "capital"}, result: "Paris"},
             %{tool: :submit, arguments: %{answer: "Paris"}, result: %{answer: "Paris"}}
           ] = DSEx.Prediction.get(prediction, :history)
  end

  test "tool argument normalization keeps unknown provider keys as strings" do
    unknown_key = "model_generated_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert %{^unknown_key => "kept", query: "capital"} =
             DSEx.Tool.normalize_arguments(%{"query" => "capital", unknown_key => "kept"})

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end

  test "string tool policies authorize normalized ReAct tool names" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: "lookup", arguments: %{query: "capital"}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> "Paris" end)

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        max_iters: 1,
        tool_policy: ["lookup"]
      )

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "Paris"}]}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "tool exceptions become structured ReAct errors" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "x"}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> raise "provider exploded" end)
    agent = DSEx.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:error, {:tool_error, :lookup, "provider exploded"}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "tool policy exceptions become structured ReAct errors" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "x"}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    policy = fn _name, _args -> raise "policy broke" end

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        tool_policy: policy,
        max_iters: 3
      )

    assert {:error, {:tool_policy_error, :lookup, "policy broke"}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "submit short-circuits later provider tool calls" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{name: :submit, arguments: %{answer: "done"}},
              %{name: :side_effect, arguments: %{}}
            ]
          }
        end
      ]
    }

    side_effect =
      DSEx.Tool.new(:side_effect, "must not run after submit", fn _args ->
        send(parent, :side_effect_ran)
        "bad"
      end)

    agent = DSEx.Predict.ReAct.new("question -> answer", [side_effect], lm: lm)

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "done"
    refute_received :side_effect_ran
    assert [%{tool: :submit}] = DSEx.Prediction.get(prediction, :history)
  end

  test "DSPy 3.2.1 mode observes tool execution failures and extracts after submit" do
    Process.put(:react_actions, [
      %{tool_calls: [%{name: :lookup, arguments: %{query: "x"}}]},
      %{tool_calls: [%{name: :submit, arguments: %{}}]},
      %{reasoning: "The failed lookup is enough context", answer: "recovered"}
    ])

    lm = sequence_lm(:react_actions)
    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> raise "provider exploded" end)

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy_3_2_1,
        max_iters: 3
      )

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "recovered"
    assert DSEx.Prediction.get(prediction, :reasoning) == "The failed lookup is enough context"
    assert DSEx.Prediction.get(prediction, :termination_reason) == :submit

    assert [
             %{
               tool: :lookup,
               result: "Execution error in lookup: provider exploded"
             },
             %{tool: :submit, result: "Completed."}
           ] = DSEx.Prediction.get(prediction, :history)

    assert Process.get(:react_actions) == []
  end

  test "DSPy 3.2.1 mode extracts after iteration exhaustion" do
    Process.put(:react_actions, [
      %{tool_calls: [%{name: :lookup, arguments: %{}}]},
      %{reasoning: "Use the observation", answer: "observed"}
    ])

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> "observed" end)

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy_3_2_1,
        max_iters: 1
      )

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "observed"
    assert DSEx.Prediction.get(prediction, :termination_reason) == :max_iters
    assert [%{tool: :lookup, result: "observed"}] = DSEx.Prediction.get(prediction, :history)
  end

  test "DSPy 3.2.1 mode makes unknown tools recoverable observations" do
    Process.put(:react_actions, [
      %{tool_calls: [%{name: "missing", arguments: %{}}]},
      %{tool_calls: [%{name: :submit, arguments: %{}}]},
      %{reasoning: "The missing tool was not needed", answer: "done"}
    ])

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [],
        lm: sequence_lm(:react_actions),
        mode: :dspy_3_2_1
      )

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})

    assert [
             %{tool: nil, result: "Execution error in missing: unknown tool"},
             %{tool: :submit, result: "Completed."}
           ] = DSEx.Prediction.get(prediction, :history)
  end

  test "DSPy 3.2.1 mode treats BEAM error tuples as recoverable observations" do
    Process.put(:react_actions, [
      %{tool_calls: [%{name: :lookup, arguments: %{}}]},
      %{tool_calls: [%{name: :submit, arguments: %{}}]},
      %{reasoning: "Recovered from the explicit error", answer: "done"}
    ])

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> {:error, :not_found} end)

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy_3_2_1
      )

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})

    assert [
             %{tool: :lookup, result: "Execution error in lookup: :not_found"},
             %{tool: :submit, result: "Completed."}
           ] = DSEx.Prediction.get(prediction, :history)
  end

  test "DSPy 3.2.1 mode extracts after action parse failure" do
    Process.put(:react_actions, [
      %{next_thought: "I cannot select an action"},
      %{reasoning: "Answer without another action", answer: "fallback"}
    ])

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [],
        lm: sequence_lm(:react_actions),
        adapter: DSEx.Adapter.JSON,
        mode: :dspy_3_2_1,
        max_iters: 2
      )

    assert {:ok, prediction} = DSEx.Predict.ReAct.call(agent, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "fallback"
    assert DSEx.Prediction.get(prediction, :termination_reason) == :parse_failure
    assert DSEx.Prediction.get(prediction, :history) == []
  end

  test "DSPy 3.2.1 mode does not weaken tool policy failures" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :react_lm_called)
          %{tool_calls: [%{name: :lookup, arguments: %{}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> raise "must not execute" end)

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy_3_2_1,
        tool_policy: []
      )

    assert {:error, {:tool_denied, :lookup}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})

    assert_received :react_lm_called
    refute_received :react_lm_called
  end

  test "DSPy 3.2.1 mode keeps malformed provider calls fail-fast" do
    Process.put(:react_actions, [
      %{tool_calls: ["not-a-tool-call"]},
      %{reasoning: "must not extract", answer: "bad"}
    ])

    agent =
      DSEx.Predict.ReAct.new("question -> answer", [],
        lm: sequence_lm(:react_actions),
        mode: :dspy_3_2_1
      )

    assert {:error, {:malformed_tool_call, "not-a-tool-call"}} =
             DSEx.Predict.ReAct.call(agent, %{question: "q"})

    assert [_unused_extraction] = Process.get(:react_actions)
  end

  test "ReAct mode defaults honestly to the existing provider-native contract" do
    agent = DSEx.Predict.ReAct.new("question -> answer", [], lm: nil)
    assert agent.mode == :provider_native

    assert_raise ArgumentError, ~r/expected one of \[:provider_native, :dspy_3_2_1\]/, fn ->
      DSEx.Predict.ReAct.new("question -> answer", [], mode: :source_faithful)
    end
  end

  defp sequence_lm(key) do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [next | rest] = Process.get(key)
          Process.put(key, rest)
          next
        end
      ]
    }
  end
end
