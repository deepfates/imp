defmodule ReActV2Test do
  use ExUnit.Case, async: true

  defmodule NativeToolStub do
    def generate_text(model, messages, opts) do
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:native_tool_request, messages, opts})

      response =
        Agent.get_and_update(state, fn
          :initial ->
            {%ReqLLM.Response{
               id: "resp_incomplete_submit",
               model: to_string(model),
               context: ReqLLM.Context.new(messages),
               message:
                 ReqLLM.Context.assistant("",
                   tool_calls: [ReqLLM.ToolCall.new("toolu_incomplete", "submit", "{}")]
                 ),
               object: nil,
               finish_reason: :tool_calls
             }, :forced}

          :forced ->
            {%ReqLLM.Response{
               id: "resp_submit",
               model: to_string(model),
               context: ReqLLM.Context.new(messages),
               message:
                 ReqLLM.Context.assistant("",
                   tool_calls: [
                     ReqLLM.ToolCall.new("toolu_submit", "submit", ~s({"answer":"Paris"}))
                   ]
                 ),
               object: nil,
               finish_reason: :tool_calls
             }, :done}
        end)

      {:ok, response}
    end
  end

  defmodule RequiredOnlyToolStub do
    def generate_text(model, messages, opts) do
      state = Keyword.fetch!(opts, :state)
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:required_only_tool_request, messages, opts})

      Agent.get_and_update(state, fn
        :initial ->
          response =
            response(model, messages, "resp_incomplete", "toolu_incomplete", "submit", "{}")

          {{:ok, response}, :named_rejected}

        :named_rejected ->
          reason =
            Keyword.get(
              opts,
              :reject_reason,
              "Invalid tool_choice type: 'object'. Supported string values: none, auto, required"
            )

          error =
            ReqLLM.Error.API.Request.exception(
              status: 400,
              reason: reason,
              response_body: %{"error" => reason}
            )

          {{:error, error}, :required}

        :required ->
          if Keyword.get(opts, :required_returns_prose, false) do
            response = prose_response(model, messages, "I will submit Paris now.")
            {{:ok, response}, :corrective}
          else
            response =
              response(
                model,
                messages,
                "resp_submit",
                "toolu_submit",
                "submit",
                ~s({"answer":"Paris"})
              )

            {{:ok, response}, :done}
          end

        :corrective ->
          if Keyword.get(opts, :extraction_fails, false) do
            error =
              ReqLLM.Error.API.Request.exception(
                status: 503,
                reason: "extraction unavailable",
                response_body: %{"error" => "extraction unavailable"}
              )

            {{:error, error}, :done}
          else
            {{:ok, extraction_response(model, messages, "Paris")}, :done}
          end

        :done ->
          if Keyword.get(opts, :extraction_fails, false) do
            error =
              ReqLLM.Error.API.Request.exception(
                status: 503,
                reason: "extraction unavailable",
                response_body: %{"error" => "extraction unavailable"}
              )

            {{:error, error}, :done}
          else
            {{:ok, extraction_response(model, messages, "Paris")}, :done}
          end
      end)
    end

    defp prose_response(model, messages, text) do
      %ReqLLM.Response{
        id: "resp_prose",
        model: to_string(model),
        context: ReqLLM.Context.new(messages),
        message: ReqLLM.Context.assistant(Jason.encode!(%{next_thought: text, tool_calls: []})),
        object: nil,
        finish_reason: :stop
      }
    end

    defp extraction_response(model, messages, answer) do
      %ReqLLM.Response{
        id: "resp_extraction",
        model: to_string(model),
        context: ReqLLM.Context.new(messages),
        message:
          ReqLLM.Context.assistant(
            Jason.encode!(%{reasoning: "The gathered evidence supports this.", answer: answer})
          ),
        object: nil,
        finish_reason: :stop
      }
    end

    defp response(model, messages, id, call_id, name, arguments) do
      %ReqLLM.Response{
        id: id,
        model: to_string(model),
        context: ReqLLM.Context.new(messages),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [ReqLLM.ToolCall.new(call_id, name, arguments)]
          ),
        object: nil,
        finish_reason: :tool_calls
      }
    end
  end

  test "executes parallel calls, preserves IDs and results, and submits final outputs" do
    parent = self()
    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found #{query}" end)

    lm =
      action_lm(
        [
          %{
            next_thought: "gather and finish",
            tool_calls: [
              %{id: "lookup-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "missing-1", name: "missing", arguments: %{}},
              %{id: "submit-1", name: "submit", arguments: %{answer: "BEAM"}}
            ]
          }
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [lookup], lm: lm)
             |> Imp.call(%{question: "What runtime?"})

    assert Imp.get(prediction, :answer) == "BEAM"
    assert Imp.get(prediction, :termination_reason) == :submit
    assert %Imp.History{messages: [event]} = Imp.get(prediction, :history)
    assert Enum.map(event.tool_calls.tool_calls, & &1.id) == ["lookup-1", "missing-1", "submit-1"]

    assert [lookup_result, missing_result, submit_result] = event.tool_call_results
    assert lookup_result.result == "found beam"
    assert missing_result.error
    assert match?({:error, {:unknown_tool, "missing"}}, missing_result.result)
    refute submit_result.error
    assert_received {:lm_call, _opts}
  end

  # Regression for de-hzcv gap #2: ReActV2 filters inputs down to signature
  # names before any Predict call, so pre-fix an extra key vanished silently.
  # Now the entry point warns (same "not in signature" surface as Predict);
  # :history and max_iters are documented call-time keys and stay silent.
  test "warns loudly on extra input keys but ignores them and still runs" do
    lm =
      action_lm([
        %{
          next_thought: "answer directly",
          tool_calls: [%{id: "submit-1", name: "submit", arguments: %{answer: "BEAM"}}]
        }
      ])

    program = Imp.react_v2("question -> answer", [], lm: lm)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, prediction} =
                 Imp.call(program, %{
                   question: "What runtime?",
                   extra_field: "should warn",
                   max_iters: 5
                 })

        assert Imp.get(prediction, :answer) == "BEAM"
      end)

    assert log =~ "not in signature"
    assert log =~ "extra_field"
    refute log =~ "max_iters"
  end

  test "denied and failed tool results reach the model as prose, not Elixir tuples" do
    assert Imp.Adapter.Chat.format_tool_result(
             {:error, {:tool_authorization_denied, :update_seen, :client_denied}}
           ) == "Error: update_seen was not allowed; the person declined it."

    assert Imp.Adapter.Chat.format_tool_result({:error, {:tool_error, :post, "boom"}}) ==
             "Error: post failed: boom"

    assert Imp.Adapter.Chat.format_tool_result({:error, :not_connected}) ==
             "Error: not connected"

    # A structured result renders as DSPy renders a dict: json.dumps, complete.
    assert Imp.Adapter.Chat.format_tool_result(%{ok: true}) == ~s({"ok": true})
  end

  test "unknown and failing tools remain history observations instead of aborting the loop" do
    broken = Imp.tool(:broken, "broken", fn _args -> raise "boom" end)

    lm =
      action_lm([
        %{tool_calls: [%{name: "broken", arguments: %{}}, %{name: "unknown", arguments: %{}}]},
        %{tool_calls: [%{name: "submit", arguments: %{answer: "recovered"}}]}
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [broken], lm: lm, max_iters: 2)
             |> Imp.call(%{question: "recover"})

    assert Imp.get(prediction, :answer) == "recovered"
    assert %Imp.History{messages: [first, _second]} = Imp.get(prediction, :history)
    assert Enum.all?(first.tool_call_results, & &1.error)
  end

  test "malformed provider tool calls become observations and cannot execute an effect" do
    parent = self()
    write = Imp.tool(:write, "write", fn arguments -> send(parent, {:write, arguments}) end)

    lm =
      action_lm([
        %{tool_calls: [%{"command" => "cat", "args" => ["/dev/null"]}]},
        %{
          tool_calls: [
            %{name: "write", arguments: %{path: "notes.txt"}},
            %{name: "submit", arguments: %{answer: "recovered"}}
          ]
        }
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [write], lm: lm, max_iters: 2)
             |> Imp.call(%{question: "write and verify"})

    assert Imp.get(prediction, :answer) == "recovered"
    assert_received {:write, %{path: "notes.txt"}}
    refute_received {:write, %{"command" => "cat"}}

    assert %Imp.History{messages: [malformed, _recovered]} = Imp.get(prediction, :history)
    assert [result] = malformed.tool_call_results
    assert result.error

    assert {:error, {:malformed_tool_call, %{"command" => "cat", "args" => ["/dev/null"]}}} =
             result.result
  end

  test "forces submit after empty calls and marks forced termination" do
    parent = self()

    lm =
      action_lm(
        [
          %{next_thought: "ready", tool_calls: []},
          %{tool_calls: [%{name: "submit", arguments: %{answer: "forced"}}]}
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm)
             |> Imp.call(%{question: "answer"})

    assert Imp.get(prediction, :answer) == "forced"
    assert Imp.get(prediction, :termination_reason) == :forced_submit
    assert_received {:lm_call, _normal_opts}
    assert_received {:lm_call, forced_opts}
    assert Keyword.fetch!(forced_opts, :tool_choice) == %{type: "tool", name: "submit"}
    assert Keyword.has_key?(forced_opts, :reasoning_effort)
    assert Keyword.get(forced_opts, :reasoning_effort) == nil
  end

  test "a forced submit on an OpenRouter client with a configured effort still runs" do
    # The live failure: a host's client carried an effort, ReAct's forced
    # submit named `reasoning_effort: nil` for that one call, and the client
    # refused the two as a collision. One option, and nil means none.
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("openrouter:provider/model",
        req_module: NativeToolStub,
        state: state,
        test_pid: self(),
        reasoning_effort: :high,
        openrouter_reasoning_wire: :nested,
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :forced_submit

    # The ordinary call carries the effort as OpenRouter's nested object (a
    # request step), not as ReqLLM's top-level option.
    assert_received {:native_tool_request, _initial_messages, initial_opts}
    refute Keyword.has_key?(initial_opts, :reasoning_effort)
    assert [_step] = get_in(initial_opts, [:req_http_options, :plugins])

    # The forced submit spends no reasoning at all.
    assert_received {:native_tool_request, _forced_messages, forced_opts}
    refute Keyword.has_key?(forced_opts, :reasoning_effort)
    assert get_in(forced_opts, [:req_http_options, :plugins]) in [nil, []]
  end

  test "forces native submit through the provider-neutral ReqLLM tool choice" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("anthropic:fixture",
        req_module: NativeToolStub,
        state: state,
        test_pid: self(),
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :forced_submit

    assert_received {:native_tool_request, _initial_messages, initial_opts}
    assert initial_opts[:tool_choice] == "auto"
    assert_received {:native_tool_request, forced_messages, forced_opts}
    assert forced_opts[:tool_choice] == %{type: "tool", name: "submit"}

    # The roster is native and the inputs are already in the history, so the
    # forced request ends on the incomplete submit's result.
    assert Enum.map(forced_messages, & &1.role) == [:system, :user, :assistant, :tool]
    assert [%ReqLLM.ToolCall{id: "toolu_incomplete"}] = Enum.at(forced_messages, 2).tool_calls
    assert Enum.at(forced_messages, 3).tool_call_id == "toolu_incomplete"
  end

  test "falls back to required with only submit when named tool choice is unsupported" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("openai:fixture",
        req_module: RequiredOnlyToolStub,
        state: state,
        test_pid: self(),
        cache: false
      )

    lookup = Imp.tool(:lookup, "Look up a fact", fn _args -> "unused" end)

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [lookup],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :forced_submit

    assert_received {:required_only_tool_request, _initial_messages, initial_opts}
    assert initial_opts[:tool_choice] == "auto"

    assert_received {:required_only_tool_request, _named_messages, named_opts}
    assert named_opts[:tool_choice] == %{type: "tool", name: "submit"}

    assert_received {:required_only_tool_request, _fallback_messages, fallback_opts}
    assert fallback_opts[:tool_choice] == "required"

    assert [submit_tool] = fallback_opts[:tools]
    assert submit_tool.name == "submit"
  end

  test "does not retry an unrelated provider rejection" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("openai:fixture",
        req_module: RequiredOnlyToolStub,
        state: state,
        test_pid: self(),
        reject_reason: "Invalid request: model is unavailable",
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :termination_reason) == :max_iters
    assert_received {:required_only_tool_request, _initial_messages, _initial_opts}
    assert_received {:required_only_tool_request, _named_messages, _named_opts}
    refute_received {:required_only_tool_request, _fallback_messages, _fallback_opts}
  end

  test "uses tools-disabled typed extraction when required-only returns no submit" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("openai:fixture",
        req_module: RequiredOnlyToolStub,
        state: state,
        test_pid: self(),
        required_returns_prose: true,
        cache: false
      )

    lookup = Imp.tool(:lookup, "Look up a fact", fn _args -> "unused" end)

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [lookup],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :termination_reason) == :forced_submit
    assert Imp.get(prediction, :completion_mode) == :typed_extraction
    assert Imp.get(prediction, :termination_cause) == :max_iters

    requests =
      for _ <- 1..5 do
        assert_received {:required_only_tool_request, messages, opts}
        {messages, opts}
      end

    assert Enum.any?(requests, fn {_messages, opts} -> opts[:tool_choice] == "auto" end)

    assert Enum.any?(requests, fn {_messages, opts} ->
             opts[:tool_choice] == %{type: "tool", name: "submit"}
           end)

    assert Enum.any?(requests, fn {_messages, opts} ->
             opts[:tool_choice] == "required" and
               match?([%ReqLLM.Tool{name: "submit"}], opts[:tools])
           end)

    assert {extraction_messages, extraction_opts} =
             Enum.find(requests, fn {_messages, opts} ->
               opts[:tool_choice] == nil and opts[:tools] in [nil, []]
             end)

    assert extraction_opts[:tool_choice] == nil
    assert extraction_opts[:tools] in [nil, []]

    extraction_prompt =
      extraction_messages
      |> Enum.flat_map(&List.wrap(&1.content))
      |> Enum.map_join("\n", fn
        text when is_binary(text) -> text
        %{text: text} when is_binary(text) -> text
        part -> inspect(part)
      end)

    assert extraction_prompt =~ "only from the original inputs and successful tool"
    assert extraction_prompt =~ "is not evidence that an action happened"
  end

  test "preserves missing output when typed extraction fails" do
    {:ok, state} = Agent.start_link(fn -> :initial end)

    lm =
      Imp.req_llm("openai:fixture",
        req_module: RequiredOnlyToolStub,
        state: state,
        test_pid: self(),
        required_returns_prose: true,
        extraction_fails: true,
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :max_iters

    for _ <- 1..5 do
      assert_received {:required_only_tool_request, _messages, _opts}
    end

    refute_received {:required_only_tool_request, _messages, _opts}
  end

  test "normalizes atom- and string-keyed tool-call collection wrappers" do
    for wrapped <- [
          %{tool_calls: [%{name: "submit", arguments: %{answer: "atom"}}]},
          %{"tool_calls" => [%{"name" => "submit", "arguments" => %{"answer" => "string"}}]},
          %{
            "tool_calls" => [
              %{
                "recipient_name" => "functions.submit",
                "parameters" => %{"answer" => "recipient"}
              }
            ]
          }
        ] do
      lm = action_lm([Imp.Prediction.new(%{tool_calls: wrapped})])

      assert {:ok, prediction} =
               Imp.react_v2("question -> answer", [], lm: lm)
               |> Imp.call(%{question: "q"})

      assert Imp.get(prediction, :answer) in ["atom", "string", "recipient"]
      assert [event] = Imp.get(prediction, :history).messages

      assert [%{id: "call_0_0", name: "submit"}] = event.tool_calls.tool_calls
    end
  end

  test "accepts atom and string per-call max_iters overrides" do
    for max_iters_key <- [:max_iters, "max_iters"] do
      parent = self()

      lm =
        action_lm(
          [
            %{tool_calls: [%{name: "lookup", arguments: %{}}]},
            %{tool_calls: [%{name: "submit", arguments: %{answer: "forced"}}]}
          ],
          parent
        )

      lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "observed" end)
      program = Imp.react_v2("question -> answer", [lookup], lm: lm, max_iters: 5)

      assert {:ok, prediction} =
               Imp.call(program, Map.put(%{question: "q"}, max_iters_key, 1))

      assert Imp.get(prediction, :answer) == "forced"
      assert Imp.get(prediction, :termination_reason) == :forced_submit
      assert_received {:lm_call, _normal_opts}
      assert_received {:lm_call, _forced_opts}
      refute_received {:lm_call, _extra_opts}
    end
  end

  test "strictly validates per-call max_iters before calling the model" do
    parent = self()
    lm = action_lm([], parent)
    program = Imp.react_v2("question -> answer", [], lm: lm)

    for invalid <- [-1, 1.0, "1", nil] do
      assert {:error, {:invalid_react_v2_max_iters, ^invalid}} =
               Imp.call(program, %{"max_iters" => invalid, question: "q"})
    end

    refute_received {:lm_call, _opts}
  end

  test "records malformed submit as an error result and returns an inspectable incomplete prediction" do
    lm =
      action_lm([
        %{tool_calls: [%{name: "submit", arguments: %{}}]},
        %{tool_calls: []}
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "q"})

    assert Imp.get(prediction, :answer) == nil
    assert Imp.get(prediction, :termination_reason) == :max_iters
    assert %Imp.History{messages: [event]} = Imp.get(prediction, :history)

    assert [%{error: true, result: {:error, {:missing_output_fields, [:answer]}}}] =
             event.tool_call_results
  end

  test "submit requires every output and validates present values even when adapters allow fallbacks" do
    signature =
      Imp.signature(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, type: :string},
          %{name: :count, type: :integer, default: 0},
          %{name: :maybe, type: :string, optional: true}
        ]
      })

    parent = self()

    lm =
      action_lm(
        [
          %{tool_calls: [%{name: "submit", arguments: %{answer: "ok"}}]},
          %{tool_calls: []}
        ],
        parent
      )

    assert {:ok, incomplete} =
             Imp.Predict.ReActV2.new(signature, [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "q"})

    assert %Imp.History{messages: [event]} = Imp.get(incomplete, :history)

    assert [%{error: true, result: {:error, {:missing_output_fields, [:count, :maybe]}}}] =
             event.tool_call_results

    assert_received {:lm_call, opts}
    submit = Enum.find(opts[:tools], &(&1.function.name == "submit"))
    assert submit.function.parameters["required"] == ["answer", "count", "maybe"]

    invalid_lm =
      action_lm([
        %{tool_calls: [%{name: "submit", arguments: %{answer: "ok", count: "no", maybe: nil}}]},
        %{tool_calls: []}
      ])

    assert {:ok, invalid} =
             Imp.Predict.ReActV2.new(signature, [], lm: invalid_lm, max_iters: 1)
             |> Imp.call(%{question: "q"})

    assert %Imp.History{messages: [invalid_event]} = Imp.get(invalid, :history)

    assert [%{error: true, result: {:error, {:invalid_submit_outputs, _reason}}}] =
             invalid_event.tool_call_results
  end

  test "accepts serialized history and reserves submit" do
    assert_raise ArgumentError, ~r/submit is reserved/, fn ->
      submit = Imp.tool(:submit, "not allowed", & &1)
      Imp.react_v2("question -> answer", [submit])
    end

    history = %{"messages" => [%{"question" => "prior", "answer" => "prior answer"}]}
    lm = action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "continued"}}]}])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 0)
             |> Imp.call(%{question: "next", history: history})

    assert Imp.get(prediction, :answer) == "continued"
    assert %Imp.History{messages: [prior, current]} = Imp.get(prediction, :history)
    assert prior.question == "prior"
    assert current.answer == "continued"
  end

  test "chat adapter replays structured history as native assistant and tool messages" do
    program = Imp.react_v2("question -> answer", [])

    history =
      Imp.History.new([
        %{
          question: "prior",
          next_thought: "checking",
          tool_calls:
            Imp.Adapter.Types.ToolCalls.new([
              %{id: "call-1", name: "lookup", arguments: %{query: "beam"}}
            ])
            |> Imp.Redaction.redact(),
          tool_call_results: [
            %{id: "call-1", name: "lookup", result: "BEAM", error: false}
          ]
        }
      ])

    messages =
      Imp.Adapter.Chat.format(program.react.signature, %{history: history, tools: []}, [])

    assert [
             %{role: :system},
             %{role: :user, content: user_content},
             %{role: :assistant, content: "checking", tool_calls: [call]},
             %{role: :tool, content: "BEAM", tool_calls: [%{id: "call-1"}]},
             %{role: :user}
           ] = messages

    assert user_content =~ "prior"

    # Replayed assistant tool calls carry the OpenAI wire shape
    # {"type": "function", "function": {"name", "arguments"}} (dee-4fuy),
    # with Imp's stable id at the top level.
    assert call.id == "call-1"
    assert call.type == "function"
    assert call.function.name == "lookup"
  end

  test "participates in LM demo and registry-backed persistence lifecycle" do
    runner = fn %{query: query} -> query end
    registry = Imp.Saving.Registry.new(lookup_runner: runner)
    tool = Imp.tool(:lookup, "lookup", runner)
    demo = Imp.example(question: "demo", answer: "demo") |> Imp.with_inputs(:question)

    program =
      Imp.react_v2("question -> answer", [tool])
      |> Imp.with_demos([demo])
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)
      |> Imp.with_lm(action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "ok"}}]}]))

    assert program.react.demos == [demo]
    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "ok"
  end

  defp action_lm(actions, notify \\ nil) do
    {:ok, state} = Agent.start_link(fn -> actions end)

    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          if notify, do: send(notify, {:lm_call, opts})

          Agent.get_and_update(state, fn
            [action | rest] -> {action, rest}
            [] -> {%{tool_calls: []}, []}
          end)
        end
      ]
    }
  end
end
