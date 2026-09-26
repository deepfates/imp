defmodule RLMPublicSurfaceTest do
  use ExUnit.Case, async: true

  test "RLM iterates through the interpreter and structured submit" do
    actions = [
      %{reasoning: "compute", code: "x + 1"},
      %{reasoning: "finish", code: ~S|submit(%{answer: "done"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      )

    Process.put(:rlm_actions, actions)

    rlm = Imp.Predict.RLM.new("x: int -> answer", lm: lm, max_iterations: 3)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{x: 1})
    assert Imp.Prediction.get(prediction, :answer) == "done"

    assert [%{action: :run, output: "2"}, %{action: :submit}] =
             prediction.metadata.rlm_trace
  after
    Process.delete(:rlm_actions)
  end

  # A model's variable names are usually not atoms in the VM; the interpreter
  # keeps them as strings, which crashed printing the failed expression.
  test "calling a value that is not a function is a failed turn the model reads" do
    parent = self()
    name = "zq_" <> "notfn"

    actions = [
      %{reasoning: "call it", code: "#{name} = 1\n#{name}.(1)"},
      %{reasoning: "finish", code: ~S|submit(%{answer: "done"})|}
    ]

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:turn, Enum.map_join(messages, "\n", &to_string(&1.content))})
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      ]
    }

    Process.put(:rlm_actions, actions)

    rlm = Imp.Predict.RLM.new("x: int -> answer", lm: lm, max_iterations: 3)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{x: 1})
    assert Imp.Prediction.get(prediction, :answer) == "done"

    assert [%{action: :run_error, output: {:error, reason}}, %{action: :submit}] =
             prediction.metadata.rlm_trace

    assert reason == {:not_a_function, name, 1}
    assert_received {:turn, _first}
    assert_received {:turn, second}
    assert second =~ "not_a_function"
  after
    Process.delete(:rlm_actions)
  end

  test "RLM gives the controller the interpreter-owned language guide" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:controller_system_prompt, hd(messages).content})
          %{code: ~S|submit(%{answer: "done"})|}
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)
    assert {:ok, _prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})

    assert_receive {:controller_system_prompt, system_prompt}
    assert system_prompt =~ Imp.Predict.RLM.Interpreter.controller_language_guide()
  end

  # The prompt names one reply shape. Offering a second one (a bare JSON
  # answer) led models to send both, joined, on their first turn.
  test "the controller prompt names one reply shape" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:controller_system_prompt, hd(messages).content})
          %{code: ~S|submit(%{answer: "done"})|}
        end
      ]
    }

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)
    assert {:ok, _prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert_receive {:controller_system_prompt, system_prompt}
    assert system_prompt =~ "Every reply is that one JSON object, including the last"
    refute system_prompt =~ "also accepted"
  end

  test "a reply of the code object joined to an answer object runs the code" do
    for reply <- [
          ~S|{"reasoning":"compute it","code":"submit(%{answer: \"Paris\"})"}| <>
            "\n" <> ~S|{"answer":"Paris"}|,
          ~S|{"answer":"Paris"}{"reasoning":"a } in a string","code":"submit(%{answer: \"Paris\"})"}|
        ] do
      lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> reply end]}
      rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 1)

      assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "Capital of France?"})
      assert Imp.Prediction.get(prediction, :answer) == "Paris"
      assert [%{action: :submit}] = prediction.metadata.rlm_trace
    end
  end

  # gpt-5.4 answered the RLM page's first turn with its action repeated, or
  # with several actions written ahead of their outputs.
  test "a reply of several code objects runs the first" do
    first = ~S|{"reasoning":"a","code":"submit(%{answer: \"A\"})"}|
    second = ~S|{"reasoning":"b","code":"submit(%{answer: \"B\"})"}|

    for reply <- [first <> "\n\n" <> first, first <> "\n\n" <> second] do
      lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> reply end]}
      rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 1)

      assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
      assert Imp.Prediction.get(prediction, :answer) == "A"
    end
  end

  test "RLM unwraps canonical LM envelopes for controller and sub-LM outputs" do
    actions = [
      Jason.encode!(%{reasoning: "query", code: ~S|result = llm_query("question")|}),
      Jason.encode!(%{reasoning: "submit", code: ~S|submit(%{answer: result["answer"]})|})
    ]

    controller =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:wrapped_rlm_actions)
          Process.put(:wrapped_rlm_actions, rest)
          %{__imp_lm_output__: action, __imp_lm_metadata__: %{provider: "test"}}
        end
      )

    sub_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            "__imp_lm_output__" => %{"answer" => "wrapped"},
            "__imp_lm_metadata__" => %{"provider" => "test"}
          }
        end
      )

    Process.put(:wrapped_rlm_actions, actions)

    rlm = Imp.Predict.RLM.new("question -> answer", lm: controller, sub_lm: sub_lm)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "wrapped"
  after
    Process.delete(:wrapped_rlm_actions)
  end

  test "RLM rejects legacy discrete action responses" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> %{"action" => "submit", "answer" => "Paris"} end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

    assert {:error,
            {:invalid_rlm_action,
             "legacy discrete action maps are unsupported; return a map with reasoning and code",
             %{"action" => "submit", "answer" => "Paris"}}} =
             Imp.Predict.RLM.call(rlm, %{question: "Capital of France?"})
  end

  test "RLM rejects unterminated action fences and redacts invalid controller text" do
    responses = [
      "```json\n{\"reasoning\":\"x\",\"code\":\"1 + 1\"}",
      "sk-secret-controller-value-123456789"
    ]

    Enum.each(responses, fn response ->
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> response end)
      rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

      assert {:error, reason} = Imp.Predict.RLM.call(rlm, %{question: "q"})
      rendered = inspect(reason)
      assert rendered =~ "action_error"
      assert rendered =~ "fingerprint"
      refute rendered =~ "sk-secret-controller-value"
    end)
  end

  test "RLM records malformed binary actions and permits controller repair" do
    Process.put(:rlm_action_repairs, [
      "controller prose instead of an action",
      Jason.encode!(%{reasoning: "repaired", code: ~S|submit(%{answer: "done"})|})
    ])

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [response | rest] = Process.get(:rlm_action_repairs)
          Process.put(:rlm_action_repairs, rest)
          response
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 2)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "done"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:action_error, :submit]
  after
    Process.delete(:rlm_action_repairs)
  end

  test "RLM accepts exactly the required outputs as a typed direct submission" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> %{"reasoning" => "finished", "answer" => "Paris"} end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "Capital of France?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert [%{action: :direct_submit}] = prediction.metadata.rlm_trace
  end

  test "RLM direct submission rejects fields outside reasoning and required outputs" do
    output = %{"reasoning" => "finished", "answer" => "Paris", "untrusted" => true}
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> output end)
    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

    assert {:error, {:invalid_rlm_action, "expected a map with a binary code field", ^output}} =
             Imp.Predict.RLM.call(rlm, %{question: "Capital of France?"})
  end

  test "RLM repairs empty typed direct submissions" do
    Process.put(:direct_submit_repairs, [%{"answer" => ""}, %{"answer" => "repaired"}])

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [output | rest] = Process.get(:direct_submit_repairs)
          Process.put(:direct_submit_repairs, rest)
          output
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 2)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "repaired"

    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) ==
             [:direct_submit_error, :direct_submit]
  after
    Process.delete(:direct_submit_repairs)
  end

  test "RLM repairs empty interpreter submissions" do
    actions = [
      %{code: ~S|submit(%{answer: ""})|},
      %{code: ~S|submit(%{answer: "repaired"})|}
    ]

    Process.put(:empty_submit_repairs, actions)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:empty_submit_repairs)
          Process.put(:empty_submit_repairs, rest)
          action
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 2)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "repaired"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:submit_error, :submit]
  after
    Process.delete(:empty_submit_repairs)
  end

  test "RLM executes persistent Elixir code with programmatic sub-LM calls" do
    actions = [
      %{
        reasoning: "split the external context",
        code: "chunks = String.split(context, \"|\")"
      },
      %{
        reasoning: "analyze every chunk inside the environment",
        code: ~S|answers = for chunk <- chunks, do: llm_query(chunk)|
      },
      %{
        reasoning: "submit the exact computed value",
        code: ~S|submit(%{answer: Enum.join(answers, " ")})|
      }
    ]

    controller =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:symbolic_rlm_actions)
          Process.put(:symbolic_rlm_actions, rest)
          action
        end
      )

    sub_lm =
      Imp.LM.Static.new(handler: fn [%{content: prompt}], _opts -> String.upcase(prompt) end)

    Process.put(:symbolic_rlm_actions, actions)

    rlm =
      Imp.Predict.RLM.new("context -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 3,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{context: "alpha|beta"})
    assert Imp.Prediction.get(prediction, :answer) == "ALPHA BETA"
    assert prediction.metadata.rlm.sub_lm_calls == 2
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run, :run, :submit]

    assert Enum.map(prediction.metadata.trajectory, &Map.take(&1, [:reasoning, :code])) ==
             Enum.map(actions, &Map.take(&1, [:reasoning, :code]))

    assert prediction.metadata.final_reasoning == "submit the exact computed value"
  after
    Process.delete(:symbolic_rlm_actions)
  end

  test "programmatic batches reserve the full shared call budget and permit repair" do
    parent = self()

    controller =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          turn = Process.get(:over_budget_turn, 0)
          Process.put(:over_budget_turn, turn + 1)

          if turn == 0,
            do: %{code: ~S|llm_query_batched(["one", "two", "three"])|},
            else: %{code: ~S|submit(%{answer: "repaired"})|}
        end
      )

    sub_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> send(parent, :unexpected_subcall) end)

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 2,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "repaired"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run_error, :submit]
    refute_received :unexpected_subcall
  after
    Process.delete(:over_budget_turn)
  end

  test "RLM code recursively invokes a child that shares the execution ledger" do
    actions = [
      %{
        reasoning: "delegate symbolically",
        code: ~S|child = recurse("question -> answer", %{question: "child"})
submit(%{answer: child[:answer]})|
      },
      %{reasoning: "answer child", code: ~S|submit(%{answer: "child answer"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:symbolic_recursive_actions)
          Process.put(:symbolic_recursive_actions, rest)
          action
        end
      )

    Process.put(:symbolic_recursive_actions, actions)

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: lm,
        max_iterations: 2,
        max_recursion_depth: 1
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "parent"})
    assert Imp.Prediction.get(prediction, :answer) == "child answer"
    assert Process.get(:symbolic_recursive_actions) == []
    assert prediction.metadata.rlm.sub_lm_calls == 0
  after
    Process.delete(:symbolic_recursive_actions)
  end

  test "legacy discrete action shapes return clear errors" do
    actions = [
      %{action: "recurse", signature: "invalid", inputs: %{}},
      %{"submit" => %{answer: "wrong"}},
      %{submit: %{answer: "wrong"}}
    ]

    Enum.each(actions, fn action ->
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> action end)

      rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

      assert {:error, {:invalid_rlm_action, message, ^action}} =
               Imp.Predict.RLM.call(rlm, %{question: "q"})

      assert message =~ "unsupported" or message =~ "submit/1"
    end)
  end

  test "RLM exposes large context as metadata and preview, not full prompt text" do
    hidden = "DO_NOT_PROMPT_FULL_CONTEXT"
    context = String.duplicate("a", 40) <> hidden

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Process.put(:rlm_controller_messages, messages)
          %{code: ~S|submit(%{answer: "ok"})|}
        end
      )

    rlm = Imp.Predict.RLM.new("context, question -> answer", lm: lm, max_preview_chars: 10)

    assert {:ok, prediction} =
             Imp.Predict.RLM.call(rlm, %{context: context, question: "what is inside?"})

    assert Imp.Prediction.get(prediction, :answer) == "ok"

    prompt = Process.get(:rlm_controller_messages) |> Enum.map_join("\n", & &1.content)
    refute prompt =~ hidden
    assert prompt =~ ~s("length":#{String.length(context)})
    assert prompt =~ ~s("truncated":true)
  after
    Process.delete(:rlm_controller_messages)
  end

  test "RLM uses extract fallback after iteration exhaustion and enforces sub-LM budgets" do
    parent = self()

    loop_then_extract_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          send(parent, {:rlm_prompt, prompt})

          if prompt =~ "RLM extract pass" do
            %{answer: "extracted"}
          else
            %{code: "x + 1"}
          end
        end
      )

    rlm = Imp.Predict.RLM.new("x: int -> answer", lm: loop_then_extract_lm, max_iterations: 1)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{x: 1})
    assert Imp.Prediction.get(prediction, :answer) == "extracted"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run, :extract]
    assert_received {:rlm_prompt, controller_prompt}
    assert controller_prompt =~ ~s("remaining_iterations":1)
    assert_received {:rlm_prompt, extract_prompt}
    assert extract_prompt =~ ~s("exhausted_at_iteration":2)

    sub_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "ok"} end)

    query_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: ~S|llm_query("q")|} end)

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: query_lm,
        sub_lm: sub_lm,
        max_llm_calls: 0
      )

    assert {:error, {:rlm_max_llm_calls, 0, _trace}} =
             Imp.Predict.RLM.call(rlm, %{question: "q"})
  after
    Process.delete(:rlm_prompt)
  end

  test "RLM rejects empty required outputs from extraction fallback" do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if Enum.any?(messages, &String.contains?(&1.content, "RLM extract pass")),
            do: %{answer: "   "},
            else: %{code: "1 + 1"}
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 1)

    assert {:error, {:rlm_extract_failed, :empty_required_output, trace}} =
             Imp.Predict.RLM.call(rlm, %{question: "q"})

    assert Enum.map(trace, & &1.action) == [:run]
  end

  # `max_preview_chars` bounds what the controller sees of every variable in
  # characters. A list was previewed as its first `max_preview_chars` items:
  # after `lines = String.split(log, "\n")` on a 20,000-line log the turn
  # message grew from 2,351 to 89,312 bytes.
  test "a list's preview is bounded in characters, not items" do
    parent = self()
    log = Enum.map_join(1..20_000, "\n", &"#{&1} INFO path=/v1/items/#{&1} status=200")

    handler = fn messages, _opts ->
      send(parent, {:turn, byte_size(List.last(messages).content)})

      if length(messages) < 4,
        do: %{code: ~S|lines = String.split(log, "\n")|},
        else: %{code: ~S|submit(%{answer: "done"})|}
    end

    lm = %{module: Imp.LM.Static, opts: [handler: handler]}
    rlm = Imp.Predict.RLM.new("log -> answer", lm: lm, max_iterations: 2)

    assert {:ok, _prediction} = Imp.Predict.RLM.call(rlm, %{log: log})
    assert_received {:turn, first_bytes}
    assert_received {:turn, second_bytes}
    assert second_bytes < first_bytes + 2_500
  end

  # A tuple, or a list or map holding one, could not be encoded into the turn
  # message at all.
  test "every variable's preview is bounded in characters" do
    parent = self()
    log = Enum.map_join(1..20_000, "\n", &"#{&1} INFO path=/v1/items/#{&1} status=200")

    handler = fn messages, _opts ->
      send(parent, {:turn, byte_size(List.last(messages).content), List.last(messages).content})

      if length(messages) < 4,
        do: %{
          code: ~S"""
          lines = String.split(log, "\n")
          rows = Enum.map(lines, fn line -> %{line => {line, String.length(line)}} end)
          index = Map.new(lines, fn line -> {line, [line]} end)
          pair = {log, lines}
          f = fn x -> x end
          big = Enum.reduce(1..12, 7, fn _, acc -> acc * acc end)
          huge = Enum.reduce(1..16, 7, fn _, acc -> acc * acc end)
          :ok
          """
        },
        else: %{code: ~S|submit(%{answer: "done"})|}
    end

    lm = %{module: Imp.LM.Static, opts: [handler: handler]}

    rlm =
      Imp.Predict.RLM.new("log -> answer",
        lm: lm,
        max_iterations: 2,
        max_preview_chars: 2_000,
        max_interpreter_steps: 1_000_000
      )

    assert {:ok, _prediction} = Imp.Predict.RLM.call(rlm, %{log: log})
    assert_received {:turn, first_bytes, _first}
    assert_received {:turn, second_bytes, second}

    variables = Jason.decode!(second)["variables"]

    for name <- ~w(log lines rows index pair f) do
      preview = get_in(variables, [name, "preview"])
      assert is_binary(preview), name
      assert String.length(preview) <= 2_000, name
      assert variables[name]["truncated"] == (name != "f"), name
    end

    assert variables["lines"]["length"] == 20_000
    assert variables["index"]["size"] == 20_000

    # 7^4096 has 3,462 digits and 7^65536 has 55,385.
    assert %{"type" => "integer", "truncated" => true, "preview" => big} = variables["big"]
    assert String.length(big) == 2_000

    assert %{"type" => "integer", "truncated" => true, "approximate_digits" => digits} =
             variables["huge"]

    assert_in_delta digits, 55_385, 100
    assert second_bytes < first_bytes + 6 * 2_500
  end

  test "RLM treats zero budgets and preview limits conservatively" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:rlm_messages, messages})
          %{code: ~S|submit(%{answer: "ok"})|}
        end
      )

    exhausted =
      Imp.Predict.RLM.new("question -> answer",
        lm: lm,
        max_iterations: 0,
        max_llm_calls: 0,
        max_time_ms: 0
      )

    assert {:error, {:rlm_max_iterations, 0, []}} =
             Imp.Predict.RLM.call(exhausted, %{question: "q"})

    refute_received {:rlm_messages, _messages}

    preview =
      Imp.Predict.RLM.new("context, values -> answer",
        lm: lm,
        max_preview_chars: 0,
        max_observation_chars: 0
      )

    assert {:ok, prediction} =
             Imp.Predict.RLM.call(preview, %{context: "secret", values: [1, 2, 3]})

    assert Imp.Prediction.get(prediction, :answer) == "ok"
    assert_received {:rlm_messages, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    assert prompt =~ ~s("preview":"")
    refute prompt =~ "secret"
    refute prompt =~ "1,2,3"
    refute prompt =~ "1, 2, 3"
  end

  test "RLM constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/Imp\.Predict\.RLM\.new\/2: expected keyword options/, fn ->
      Imp.Predict.RLM.new("question -> answer", %{lm: nil})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RLM\.new\/2: invalid value for :tools option: expected a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.RLM.new("question -> answer", tools: :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RLM\.new\/2: invalid value for :tools option: expected a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.RLM.new("question -> answer", tools: [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RLM\.new\/2: invalid value for :max_iterations option: expected non negative integer/,
                 fn ->
                   Imp.Predict.RLM.new("question -> answer", max_iterations: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RLM\.new\/2: invalid value for :max_preview_chars option: expected non negative integer/,
                 fn ->
                   Imp.Predict.RLM.new("question -> answer", max_preview_chars: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.RLM\.new\/2: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   Imp.Predict.RLM.new("question -> answer", tool_policy: %{only: :lookup})
                 end

    rlm = Imp.Predict.RLM.new("question -> answer", lm: nil)

    assert {:error, {:invalid_rlm_inputs, message}} = Imp.Predict.RLM.call(rlm, :not_inputs)
    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_rlm_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.Predict.RLM.call(rlm, [:not_a_pair])

    assert {:error, {:missing_input_fields, [:question]}} =
             Imp.Predict.RLM.call(rlm, %{})
  end

  test "RLM supports persistent assignment and tool calls" do
    actions = [
      %{code: ~S|scratch = "Paris"|},
      %{code: ~S|fact = lookup(%{key: "capital"})|},
      %{code: ~S|submit(%{answer: scratch})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Process.put(:rlm_tool_prompt, Enum.map_join(messages, "\n", & &1.content))
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup a key", fn %{key: "capital"} -> "Paris" end)
    Process.put(:rlm_actions, actions)

    rlm =
      Imp.Predict.RLM.new("question -> answer", lm: lm, tools: [lookup], max_iterations: 4)

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert Process.get(:rlm_tool_prompt) =~ "lookup a key"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run, :run, :submit]
  after
    Process.delete(:rlm_actions)
    Process.delete(:rlm_tool_prompt)
  end

  test "assignment is visible to the authoritative symbolic environment" do
    actions = [
      %{reasoning: "assign in code", code: ~S|derived = 42|},
      %{reasoning: "use interpreter state", code: ~S|submit(%{answer: derived})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:mixed_rlm_actions)
          Process.put(:mixed_rlm_actions, rest)
          action
        end
      )

    Process.put(:mixed_rlm_actions, actions)
    rlm = Imp.Predict.RLM.new("question -> answer: integer", lm: lm)

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == 42
  after
    Process.delete(:mixed_rlm_actions)
  end

  test "RLM loads sandbox serializable inputs explicitly without prompt leakage" do
    parent = self()

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    serializable =
      Imp.rlm_serializable(
        :context,
        fn ->
          Agent.update(counter, &(&1 + 1))
          "classified-secret-context"
        end,
        metadata: %{source: "fixture", bytes: 25}
      )

    actions = [
      %{code: ~S|context = load("context")|},
      %{code: "String.length(context)"},
      %{code: ~S|submit(%{answer: "loaded"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:rlm_serializable_prompt, Enum.map_join(messages, "\n", & &1.content)})
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      )

    Process.put(:rlm_actions, actions)

    rlm =
      Imp.Predict.RLM.new("context, question -> answer",
        lm: lm,
        max_preview_chars: 6,
        max_observation_chars: 6
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{context: serializable, question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "loaded"
    assert Agent.get(counter, & &1) == 1

    assert_received {:rlm_serializable_prompt, first_prompt}
    assert first_prompt =~ "sandbox_serializable"
    assert first_prompt =~ "fixture"
    refute first_prompt =~ "classified-secret-context"

    assert_received {:rlm_serializable_prompt, second_prompt}
    assert second_prompt =~ ~s("preview":"classi")
    refute second_prompt =~ "classified-secret-context"

    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run, :run, :submit]
  after
    Process.delete(:rlm_actions)
  end

  test "RLM exposes optimizer-visible internal predictors" do
    lm = Imp.LM.Static.new()
    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm)

    assert %{
             action: %Imp.Predict{},
             extract: %Imp.Predict{},
             subquery: %Imp.Predict{}
           } = Imp.ProgramAccess.internal_predictors(rlm)

    assert Imp.ProgramAccess.task_signature(rlm) == rlm.signature
  end

  test "RLM feeds invalid submit errors back for another controller attempt" do
    actions = [
      %{code: ~S|submit(%{not_answer: "wrong"})|},
      %{code: ~S|submit(%{answer: "corrected"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Process.put(:rlm_submit_prompt, Enum.map_join(messages, "\n", & &1.content))
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      )

    Process.put(:rlm_actions, actions)

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 3)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "corrected"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:submit_error, :submit]
    assert Process.get(:rlm_submit_prompt) =~ "not_answer"
  after
    Process.delete(:rlm_actions)
    Process.delete(:rlm_submit_prompt)
  end

  test "RLM supports batched sub-LM queries with per-prompt budget accounting" do
    parent = self()

    sub_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          send(parent, {:sub_prompt, prompt})
          %{answer: if(prompt =~ "first", do: "one", else: "two")}
        end
      )

    actions = [
      %{
        code: ~S|results = llm_query_batched(["first", "second"])|
      },
      %{code: ~S|submit(%{answer: "done"})|}
    ]

    {:ok, action_queue} = Agent.start_link(fn -> actions end)

    controller_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(action_queue, fn [action | rest] -> {action, rest} end)
        end
      )

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: controller_lm,
        sub_lm: sub_lm,
        max_iterations: 3,
        max_llm_calls: 2
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "parent"})
    assert Imp.Prediction.get(prediction, :answer) == "done"

    assert [%{action: :run, output: output}, %{action: :submit}] =
             prediction.metadata.rlm_trace

    assert output =~ "one"
    assert output =~ "two"

    assert_received {:sub_prompt, prompt_a}
    assert_received {:sub_prompt, prompt_b}
    assert Enum.any?([prompt_a, prompt_b], &String.contains?(&1, "first"))
    assert Enum.any?([prompt_a, prompt_b], &String.contains?(&1, "second"))

    Agent.stop(action_queue)
    {:ok, over_budget_queue} = Agent.start_link(fn -> actions end)

    over_budget_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(over_budget_queue, fn [action | rest] -> {action, rest} end)
        end
      )

    over_budget =
      Imp.Predict.RLM.new("question -> answer",
        lm: over_budget_lm,
        sub_lm: sub_lm,
        max_iterations: 3,
        max_llm_calls: 1
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(over_budget, %{question: "parent"})
    assert Imp.Prediction.get(prediction, :answer) == "done"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run_error, :submit]

    Agent.stop(over_budget_queue)
  end

  test "RLM executes tool calls from the interpreter" do
    actions = [
      %{code: ~S|lookup(%{key: "capital"})|},
      %{code: ~S|submit(%{answer: "Paris"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_actions)
          Process.put(:rlm_actions, rest)
          action
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup a key", fn %{key: "capital"} -> "Paris" end)
    Process.put(:rlm_actions, actions)

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, tools: [lookup], max_iterations: 3)

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"

    assert %{action: :run, output: "\"Paris\""} = hd(prediction.metadata.rlm_trace)
  after
    Process.delete(:rlm_actions)
  end

  test "RLM supports genuine recursive child calls with reduced budget" do
    actions = [
      %{code: ~S|child = recurse("question -> answer", %{question: "child"})|},
      %{code: ~S|submit(%{answer: "child answer"})|},
      %{code: ~S|submit(%{answer: "parent answer"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_recurse_actions)
          Process.put(:rlm_recurse_actions, rest)
          action
        end
      )

    Process.put(:rlm_recurse_actions, actions)

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 4)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "parent"})
    assert Imp.Prediction.get(prediction, :answer) == "parent answer"

    assert [%{action: :run, output: "%{answer: \"child answer\"}"}, %{action: :submit}] =
             prediction.metadata.rlm_trace

    assert [%{action: :recurse, depth: 1, trace: child_trace}] =
             prediction.metadata.rlm_child_traces

    assert Enum.map(child_trace, & &1.action) == [:submit]
    assert prediction.metadata.rlm.max_observed_depth == 1
  after
    Process.delete(:rlm_recurse_actions)
  end

  test "recursive children validate their required inputs" do
    actions = [
      %{code: ~S|recurse("question, context -> answer", %{question: "child"})|},
      %{code: ~S|submit(%{answer: "repaired"})|}
    ]

    Process.put(:rlm_invalid_child_actions, actions)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rlm_invalid_child_actions)
          Process.put(:rlm_invalid_child_actions, rest)
          action
        end
      )

    rlm = Imp.Predict.RLM.new("question -> answer", lm: lm, max_iterations: 2)
    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "parent"})
    assert Imp.Prediction.get(prediction, :answer) == "repaired"
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run_error, :submit]
    assert inspect(hd(prediction.metadata.rlm_trace).output) =~ "missing_input_fields"
  after
    Process.delete(:rlm_invalid_child_actions)
  end

  test "RLM tool failures become repairable interpreter observations" do
    cases = [
      {
        ~S|lookup(%{})|,
        [Imp.Tool.new(:lookup, "lookup", fn _ -> :ok end)],
        [],
        {:rlm_tool_error, {:tool_authorization_denied, :lookup, :tool_policy}}
      },
      {~S|missing_tool(%{})|, [], :allow, {:function_not_allowed, :missing_tool}},
      {
        ~S|boom(%{})|,
        [Imp.Tool.new(:boom, "boom", fn _ -> raise "tool exploded" end)],
        :allow,
        {:rlm_tool_error, {:tool_error, :boom, %RuntimeError{message: "tool exploded"}}}
      },
      {
        ~S|lookup(%{})|,
        [Imp.Tool.new(:lookup, "lookup", fn _ -> :ok end)],
        fn _name, _args -> raise "policy exploded" end,
        {:rlm_tool_error,
         {:tool_policy_error, :lookup, %RuntimeError{message: "policy exploded"}}}
      }
    ]

    Enum.each(cases, fn {code, tools, tool_policy, expected} ->
      {:ok, turns} = Agent.start_link(fn -> 0 end)

      lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            Agent.get_and_update(turns, fn
              0 -> {%{code: code}, 1}
              _ -> {%{code: ~S|submit(%{answer: "repaired"})|}, 1}
            end)
          end
        )

      rlm =
        Imp.Predict.RLM.new("question -> answer",
          lm: lm,
          tools: tools,
          tool_policy: tool_policy,
          max_iterations: 2
        )

      assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
      assert Imp.Prediction.get(prediction, :answer) == "repaired"

      assert [
               %{action: :run_error, output: {:error, ^expected}},
               %{action: :submit}
             ] =
               prediction.metadata.rlm_trace

      Agent.stop(turns)
    end)
  end

  test "RLM bounds large tool observations and traces without retaining payload content" do
    payload = String.duplicate("private-medical-record-", 20_000)
    echo = Imp.tool(:echo, "return a large trusted payload", fn _args -> payload end)

    actions = [
      %{code: ~S|echo(%{})|},
      %{code: ~S|submit(%{answer: "ok"})|}
    ]

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:bounded_trace_actions)
          Process.put(:bounded_trace_actions, rest)
          action
        end
      )

    Process.put(:bounded_trace_actions, actions)

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: lm,
        tools: [echo],
        max_observation_chars: 1_000
      )

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    trace = prediction.metadata.rlm_trace
    assert :erlang.external_size(trace) < 10_000
    refute inspect(trace) =~ payload

    assert hd(trace).output == "[REDACTED]" or
             (is_map(hd(trace).output) and hd(trace).output.truncated)
  after
    Process.delete(:bounded_trace_actions)
  end

  test "RLM enforces wall-clock budget" do
    timeout_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Process.sleep(2)
          %{code: "1 + 1"}
        end
      )

    timeout = Imp.Predict.RLM.new("question -> answer", lm: timeout_lm, max_time_ms: 0)

    assert {:error, {:rlm_max_time_ms, 0, _trace}} =
             Imp.Predict.RLM.call(timeout, %{question: "q"})
  end

  test "RLM deadline interrupts a blocked sub-LM effect" do
    controller =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: ~S|llm_query("slow")|} end)

    sub_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Process.sleep(250)
          "late"
        end
      )

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_time_ms: 100
      )

    {elapsed_us, result} = :timer.tc(fn -> Imp.Predict.RLM.call(rlm, %{question: "q"}) end)

    assert {:error, {:rlm_time_budget_exceeded, _trace}} = result
    assert elapsed_us < 500_000
  end

  test "batched subqueries obey one absolute deadline across concurrency waves" do
    parent = self()
    run_ref = make_ref()
    prompts = Enum.map(1..24, &"prompt-#{&1}")
    code = "llm_query_batched(#{inspect(prompts)})"

    controller = Imp.LM.Static.new(handler: fn _messages, _opts -> %{code: code} end)

    sub_lm =
      Imp.LM.Static.new(
        handler: fn [%{content: prompt}], _opts ->
          send(parent, {:batch_started, run_ref, prompt})
          Process.sleep(80)
          send(parent, {:batch_finished, run_ref, prompt})
          prompt
        end
      )

    rlm =
      Imp.Predict.RLM.new("question -> answer",
        lm: controller,
        sub_lm: sub_lm,
        max_iterations: 1,
        max_llm_calls: 24,
        max_time_ms: 150
      )

    {elapsed_us, result} = :timer.tc(fn -> Imp.Predict.RLM.call(rlm, %{question: "q"}) end)

    assert {:error, _reason} = result
    assert elapsed_us < 400_000
    drain_batch_messages(run_ref)
    refute_receive {:batch_finished, ^run_ref, _prompt}, 150
  end

  defp drain_batch_messages(run_ref) do
    receive do
      {:batch_started, ^run_ref, _prompt} -> drain_batch_messages(run_ref)
      {:batch_finished, ^run_ref, _prompt} -> drain_batch_messages(run_ref)
    after
      0 -> :ok
    end
  end
end
