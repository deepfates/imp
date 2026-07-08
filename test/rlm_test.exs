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

  test "RLM treats zero budgets and preview limits conservatively" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:rlm_messages, messages})
          %{action: "submit", result: %{answer: "ok"}}
        end
      ]
    }

    exhausted =
      DSEx.Predict.RLM.new("question -> answer",
        lm: lm,
        max_iterations: 0,
        max_llm_calls: 0,
        max_time_ms: 0
      )

    assert {:error, {:rlm_max_iterations, 0, []}} =
             DSEx.Predict.RLM.call(exhausted, %{question: "q"})

    refute_received {:rlm_messages, _messages}

    preview =
      DSEx.Predict.RLM.new("context, values -> answer",
        lm: lm,
        max_preview_chars: 0,
        max_observation_chars: 0
      )

    assert {:ok, prediction} =
             DSEx.Predict.RLM.call(preview, %{context: "secret", values: [1, 2, 3]})

    assert DSEx.Prediction.get(prediction, :answer) == "ok"
    assert_received {:rlm_messages, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    assert prompt =~ ~s("preview":"")
    assert prompt =~ ~s("preview":[])
    refute prompt =~ "secret"
    refute prompt =~ "1,2,3"
  end

  test "RLM constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/DSEx\.Predict\.RLM\.new\/2: expected keyword options/, fn ->
      DSEx.Predict.RLM.new("question -> answer", %{lm: nil})
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RLM\.new\/2 expects :tools to be a list of DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.RLM.new("question -> answer", tools: :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RLM\.new\/2 expects :tools to contain DSEx\.Tool structs/,
                 fn ->
                   DSEx.Predict.RLM.new("question -> answer", tools: [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RLM\.new\/2: invalid value for :max_iterations option: expected non negative integer/,
                 fn ->
                   DSEx.Predict.RLM.new("question -> answer", max_iterations: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RLM\.new\/2: invalid value for :max_preview_chars option: expected non negative integer/,
                 fn ->
                   DSEx.Predict.RLM.new("question -> answer", max_preview_chars: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Predict\.RLM\.new\/2: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   DSEx.Predict.RLM.new("question -> answer", tool_policy: %{only: :lookup})
                 end

    rlm = DSEx.Predict.RLM.new("question -> answer", lm: nil)

    assert {:error, {:invalid_rlm_inputs, message}} = DSEx.Predict.RLM.call(rlm, :not_inputs)
    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_rlm_inputs, "expected inputs as {key, value} pairs"}} =
             DSEx.Predict.RLM.call(rlm, [:not_a_pair])
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

  test "RLM decodes JSON string tool arguments before execution" do
    actions = [
      %{action: "tool", name: "lookup", arguments: ~s({"key":"capital"})},
      %{action: "submit", result: %{answer: "Paris"}}
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

    lookup = DSEx.Tool.new(:lookup, "lookup a key", fn %{"key" => "capital"} -> "Paris" end)
    Process.put(:rlm_actions, actions)

    rlm = DSEx.Predict.RLM.new("question -> answer", lm: lm, tools: [lookup], max_iterations: 3)

    assert {:ok, prediction} = DSEx.Predict.RLM.call(rlm, %{question: "q"})
    assert DSEx.Prediction.get(prediction, :answer) == "Paris"

    assert %{action: :tool, input: %{"arguments" => ~s({"key":"capital"})}, output: "Paris"} =
             hd(prediction.metadata.rlm_trace)
  after
    Process.delete(:rlm_actions)
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

  test "RLM tool failures stop with structured trace-bearing errors" do
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

    assert {:error, {:rlm_tool_error, {:tool_denied, :lookup}, [denied_trace]}} =
             DSEx.Predict.RLM.call(denied, %{question: "q"})

    assert %{action: :tool, output: {:error, {:tool_denied, :lookup}}} = denied_trace

    unknown_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{action: "tool", name: "missing_tool", arguments: %{}}
        end
      ]
    }

    unknown = DSEx.Predict.RLM.new("question -> answer", lm: unknown_lm, tools: [])

    assert {:error, {:rlm_tool_error, {:unknown_tool, "missing_tool"}, [unknown_trace]}} =
             DSEx.Predict.RLM.call(unknown, %{question: "q"})

    assert %{action: :tool, output: {:error, {:unknown_tool, "missing_tool"}}} = unknown_trace

    crashing_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{action: "tool", name: "boom", arguments: %{}}
        end
      ]
    }

    boom = DSEx.Tool.new(:boom, "boom", fn _args -> raise "tool exploded" end)
    crashing = DSEx.Predict.RLM.new("question -> answer", lm: crashing_lm, tools: [boom])

    assert {:error, {:rlm_tool_error, {:tool_error, :boom, "tool exploded"}, [boom_trace]}} =
             DSEx.Predict.RLM.call(crashing, %{question: "q"})

    assert %{action: :tool, output: {:error, {:tool_error, :boom, "tool exploded"}}} =
             boom_trace

    policy_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          %{action: "tool", name: "lookup", arguments: %{}}
        end
      ]
    }

    policy =
      DSEx.Predict.RLM.new("question -> answer",
        lm: policy_lm,
        tools: [lookup],
        tool_policy: fn _name, _args -> raise "policy exploded" end
      )

    assert {:error,
            {:rlm_tool_error, {:tool_policy_error, :lookup, "policy exploded"}, [policy_trace]}} =
             DSEx.Predict.RLM.call(policy, %{question: "q"})

    assert %{action: :tool, output: {:error, {:tool_policy_error, :lookup, "policy exploded"}}} =
             policy_trace
  end

  test "RLM enforces wall-clock budget" do
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
