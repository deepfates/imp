defmodule RLMParityTest do
  use ExUnit.Case, async: true

  test "RLM iterates through sandbox eval and structured submit" do
    actions = [
      %{action: "eval", code: "x + 1"},
      %{action: "submit", result: %{answer: "done"}}
    ]

    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_actions, actions)

    rlm = DSPy.Predict.RLM.new("x: int -> answer", lm: lm, max_iterations: 3)
    assert {:ok, prediction} = DSPy.Predict.RLM.call(rlm, %{x: 1})
    assert DSPy.Prediction.get(prediction, :answer) == "done"

    assert [%{action: :eval, output: {:ok, 2}}, %{action: :submit}] =
             prediction.metadata.rlm_trace
  after
    Process.delete(:rlm_actions)
  end

  test "RLM exposes large context as metadata and preview, not full prompt text" do
    hidden = "DO_NOT_PROMPT_FULL_CONTEXT"
    context = String.duplicate("a", 40) <> hidden

    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          Process.put(:rlm_controller_messages, messages)
          %{action: "submit", result: %{answer: "ok"}}
        end
      ]
    }

    rlm = DSPy.Predict.RLM.new("context, question -> answer", lm: lm, max_preview_chars: 10)

    assert {:ok, prediction} =
             DSPy.Predict.RLM.call(rlm, %{context: context, question: "what is inside?"})

    assert DSPy.Prediction.get(prediction, :answer) == "ok"

    prompt = Process.get(:rlm_controller_messages) |> Enum.map_join("\n", & &1.content)
    refute prompt =~ hidden
    assert prompt =~ ~s("length":#{String.length(context)})
    assert prompt =~ ~s("truncated":true)
  after
    Process.delete(:rlm_controller_messages)
  end

  test "RLM enforces max iteration and sub-LM budgets" do
    loop_lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{action: "eval", code: "x + 1"} end]
    }

    rlm = DSPy.Predict.RLM.new("x: int -> answer", lm: loop_lm, max_iterations: 1)
    assert {:error, {:rlm_max_iterations, 1, _trace}} = DSPy.Predict.RLM.call(rlm, %{x: 1})

    sub_lm = %{module: DSPy.LM.Fake, opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]}

    query_lm = %{
      module: DSPy.LM.Fake,
      opts: [handler: fn _messages, _opts -> %{action: "llm_query", inputs: %{question: "q"}} end]
    }

    rlm =
      DSPy.Predict.RLM.new("question -> answer", lm: query_lm, sub_lm: sub_lm, max_llm_calls: 0)

    assert {:error, {:rlm_max_llm_calls, 0, _trace}} =
             DSPy.Predict.RLM.call(rlm, %{question: "q"})
  end
end
