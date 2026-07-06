defmodule ReActV2ContractTest do
  use ExUnit.Case, async: true

  test "submit must provide required signature outputs" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{extra: "only"}}]}
        end
      ]
    }

    agent = Dachshund.Predict.ReActV2.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:missing_output_fields, [:answer]}} =
             Dachshund.Predict.ReActV2.call(agent, %{question: "q"})
  end

  test "tool policy denial stops ReActV2 before executing LM-selected tool" do
    lm = %{
      module: Dachshund.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "secret"}}]}
        end
      ]
    }

    lookup = Dachshund.Tool.new(:lookup, "lookup", fn _args -> raise "should not run" end)
    agent = Dachshund.Predict.ReActV2.new("question -> answer", [lookup], lm: lm, tool_policy: [])

    assert {:error, {:tool_denied, :lookup}} =
             Dachshund.Predict.ReActV2.call(agent, %{question: "q"})
  end
end
