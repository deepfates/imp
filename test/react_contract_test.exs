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
end
