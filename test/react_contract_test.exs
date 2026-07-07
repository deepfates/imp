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
