defmodule RLMPublicSurfaceTest do
  use ExUnit.Case, async: true

  test "RLM iterates through sandbox eval and structured submit" do
    actions = [
      %{action: "eval", code: "x + 1"},
      %{action: "submit", result: %{answer: "done"}}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_actions, actions)

    rlm = DSEx.Predict.RLM.new("x: int -> answer", lm: lm, max_iterations: 3)
    assert {:ok, prediction} = DSEx.Predict.RLM.call(rlm, %{x: 1})
    assert DSEx.Prediction.get(prediction, :answer) == "done"

    assert [%{action: :eval, output: {:ok, 2}}, %{action: :submit}] =
             prediction.metadata.rlm_trace
  after
    Process.delete(:rlm_actions)
  end

  test "RLM exposes large context as metadata and preview, not full prompt text" do
    hidden = "DO_NOT_PROMPT_FULL_CONTEXT"
    context = String.duplicate("a", 40) <> hidden

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          Process.put(:rlm_controller_messages, messages)
          %{action: "submit", result: %{answer: "ok"}}
        end
      ]
    }

    rlm = DSEx.Predict.RLM.new("context, question -> answer", lm: lm, max_preview_chars: 10)

    assert {:ok, prediction} =
             DSEx.Predict.RLM.call(rlm, %{context: context, question: "what is inside?"})

    assert DSEx.Prediction.get(prediction, :answer) == "ok"

    prompt = Process.get(:rlm_controller_messages) |> Enum.map_join("\n", & &1.content)
    refute prompt =~ hidden
    assert prompt =~ ~s("length":#{String.length(context)})
    assert prompt =~ ~s("truncated":true)
  after
    Process.delete(:rlm_controller_messages)
  end

  test "RLM enforces max iteration and sub-LM budgets" do
    loop_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{action: "eval", code: "x + 1"} end]
    }

    rlm = DSEx.Predict.RLM.new("x: int -> answer", lm: loop_lm, max_iterations: 1)
    assert {:error, {:rlm_max_iterations, 1, _trace}} = DSEx.Predict.RLM.call(rlm, %{x: 1})

    sub_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "ok"} end]
    }

    query_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{action: "llm_query", inputs: %{question: "q"}} end]
    }

    rlm =
      DSEx.Predict.RLM.new("question -> answer",
        lm: query_lm,
        sub_lm: sub_lm,
        max_llm_calls: 0
      )

    assert {:error, {:rlm_max_llm_calls, 0, _trace}} =
             DSEx.Predict.RLM.call(rlm, %{question: "q"})
  end

  test "RLM supports persistent assignment and tool actions" do
    actions = [
      %{action: "assign", name: "scratch", value: "Paris"},
      %{action: "tool", name: "lookup", arguments: %{"key" => "capital"}},
      %{action: "submit", result: %{answer: "Paris"}}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          Process.put(:rlm_tool_prompt, Enum.map_join(messages, "\n", & &1.content))
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup a key", fn %{"key" => "capital"} -> "Paris" end)
    Process.put(:rlm_actions, actions)

    rlm =
      DSEx.Predict.RLM.new("question -> answer", lm: lm, tools: [lookup], max_iterations: 4)

    assert {:ok, prediction} = DSEx.Predict.RLM.call(rlm, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"
    assert Process.get(:rlm_tool_prompt) =~ "lookup a key"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:assign, :tool, :submit]
  after
    Process.delete(:rlm_actions)
    Process.delete(:rlm_tool_prompt)
  end

  test "RLM supports genuine recursive child calls with reduced budget" do
    actions = [
      %{action: "recurse", signature: "question -> answer", inputs: %{question: "child"}},
      %{action: "submit", result: %{answer: "child answer"}},
      %{action: "submit", result: %{answer: "parent answer"}}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_recurse_actions)
          Process.put(:rlm_recurse_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_recurse_actions, actions)

    rlm = DSEx.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 4)
    assert {:ok, prediction} = DSEx.Predict.RLM.call(rlm, %{question: "parent"})
    assert DSEx.Prediction.get(prediction, :answer) == "parent answer"

    assert [%{action: :recurse, output: {:ok, child}}, %{action: :submit}] =
             prediction.metadata.rlm_trace

    assert DSEx.Prediction.get(child, :answer) == "child answer"
  after
    Process.delete(:rlm_recurse_actions)
  end

  test "RLM enforces tool policy and wall-clock budget" do
    denied_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts -> %{action: "tool", name: "lookup", arguments: %{}} end
      ]
    }

    lookup = DSEx.Tool.new(:lookup, "lookup", fn _ -> :ok end)

    denied =
      DSEx.Predict.RLM.new("question -> answer",
        lm: denied_lm,
        tools: [lookup],
        tool_policy: []
      )

    assert {:error, {:tool_denied, :lookup}} =
             DSEx.Predict.RLM.call(denied, %{question: "q"})

    timeout_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Process.sleep(2)
          %{action: "eval", code: "1 + 1"}
        end
      ]
    }

    timeout = DSEx.Predict.RLM.new("question -> answer", lm: timeout_lm, max_time_ms: 0)

    assert {:error, {:rlm_max_time_ms, 0, _trace}} =
             DSEx.Predict.RLM.call(timeout, %{question: "q"})
  end
end
