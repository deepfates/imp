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

  test "RLM supports persistent assignment and tool actions" do
    actions = [
      %{action: "assign", name: "scratch", value: "Paris"},
      %{action: "tool", name: "lookup", arguments: %{"key" => "capital"}},
      %{action: "submit", result: %{answer: "Paris"}}
    ]

    lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          Process.put(:rlm_tool_prompt, Enum.map_join(messages, "\n", & &1.content))
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      ]
    }

    lookup = DSPy.Tool.new(:lookup, "lookup a key", fn %{"key" => "capital"} -> "Paris" end)
    Process.put(:rlm_actions, actions)

    rlm = DSPy.Predict.RLM.new("question -> answer", lm: lm, tools: [lookup], max_iterations: 4)

    assert {:ok, prediction} = DSPy.Predict.RLM.call(rlm, %{question: "q"})
    assert DSPy.Prediction.get(prediction, :answer) == "Paris"
    assert Process.get(:rlm_tool_prompt) =~ "lookup a key"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:assign, :tool, :submit]
  after
    Process.delete(:rlm_actions)
    Process.delete(:rlm_tool_prompt)
  end

  test "RLM enforces tool policy and wall-clock budget" do
    denied_lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts -> %{action: "tool", name: "lookup", arguments: %{}} end
      ]
    }

    lookup = DSPy.Tool.new(:lookup, "lookup", fn _ -> :ok end)

    denied =
      DSPy.Predict.RLM.new("question -> answer", lm: denied_lm, tools: [lookup], tool_policy: [])

    assert {:error, {:tool_denied, :lookup}} = DSPy.Predict.RLM.call(denied, %{question: "q"})

    timeout_lm = %{
      module: DSPy.LM.Fake,
      opts: [
        handler: fn _messages, _opts ->
          Process.sleep(2)
          %{action: "eval", code: "1 + 1"}
        end
      ]
    }

    timeout = DSPy.Predict.RLM.new("question -> answer", lm: timeout_lm, max_time_ms: 0)

    assert {:error, {:rlm_max_time_ms, 0, _trace}} =
             DSPy.Predict.RLM.call(timeout, %{question: "q"})
  end
end
