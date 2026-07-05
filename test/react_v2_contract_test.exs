defmodule ReActV2ContractTest do
  use ExUnit.Case, async: true

  test "submit must provide required signature outputs" do
    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{extra: "only"}}]}
        end
      ]
    }

    agent = DSPy.Predict.ReActV2.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:missing_output_fields, [:answer]}} =
             DSPy.Predict.ReActV2.call(agent, %{question: "q"})
  end
end
