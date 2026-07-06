defmodule ReActV2ContractTest do
  use ExUnit.Case, async: true

  test "submit must provide required signature outputs" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{extra: "only"}}]}
        end
      ]
    }

    agent = DSEx.Predict.ReActV2.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:missing_output_fields, [:answer]}} =
             DSEx.Predict.ReActV2.call(agent, %{question: "q"})
  end

  test "tool policy denial stops ReActV2 before executing LM-selected tool" do
    lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "secret"}}]}
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _args -> raise "should not run" end)
    agent = DSEx.Predict.ReActV2.new("question -> answer", [lookup], lm: lm, tool_policy: [])

    assert {:error, {:tool_denied, :lookup}} =
             DSEx.Predict.ReActV2.call(agent, %{question: "q"})
  end
end
