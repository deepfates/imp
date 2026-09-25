defmodule ReActV2Test do
  use ExUnit.Case, async: true

  # A signature with more than one output keeps DSPy's `submit`; the tests of
  # the submit path use it. `question -> answer` has one text output, so its
  # loop has no `submit` and the answer is the prose the model writes.
  @submit_signature "question -> answer, confidence: float"

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
                     ReqLLM.ToolCall.new(
                       "toolu_submit",
                       "submit",
                       ~s({"answer":"Paris","confidence":0.9})
                     )
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
          if Keyword.get(opts, :required_returns_text, false) do
            response = text_response(model, messages, "I will submit Paris now.")
            {{:ok, response}, :corrective}
          else
            response =
              response(
                model,
                messages,
                "resp_submit",
                "toolu_submit",
                "submit",
                ~s({"answer":"Paris","confidence":0.9})
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

    defp text_response(model, messages, text) do
      %ReqLLM.Response{
        id: "resp_text",
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
            Jason.encode!(%{
              reasoning: "The gathered evidence supports this.",
              answer: answer,
              confidence: 0.9
            })
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
    lookup = Imp.tool(:lookup, "lookup", fn %{"query" => query} -> "found #{query}" end)

    lm =
      action_lm(
        [
          %{
            next_thought: "gather and finish",
            tool_calls: [
              %{id: "lookup-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "missing-1", name: "missing", arguments: %{}},
              %{
                id: "submit-1",
                name: "submit",
                arguments: %{answer: "BEAM", confidence: 1.0}
              }
            ]
          }
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [lookup], lm: lm)
             |> Imp.call(%{question: "What runtime?"})

    assert Imp.get(prediction, :answer) == "BEAM"
    assert prediction.metadata[:termination_reason] == :submit
    assert %Imp.History{messages: [event]} = prediction.metadata[:history]
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
        "BEAM"
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
             {:error, {:tool_denied, :update_seen, :client_denied}}
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
        "recovered"
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [broken], lm: lm, max_iters: 2)
             |> Imp.call(%{question: "recover"})

    assert Imp.get(prediction, :answer) == "recovered"
    assert %Imp.History{messages: [first, _second]} = prediction.metadata[:history]
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
            %{name: "submit", arguments: %{answer: "recovered", confidence: 1.0}}
          ]
        }
      ])

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [write], lm: lm, max_iters: 2)
             |> Imp.call(%{question: "write and verify"})

    assert Imp.get(prediction, :answer) == "recovered"
    assert_received {:write, %{"path" => "notes.txt"}}
    refute_received {:write, %{"command" => "cat"}}

    assert %Imp.History{messages: [malformed, _recovered]} = prediction.metadata[:history]
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
          %{tool_calls: [%{name: "submit", arguments: %{answer: "forced", confidence: 1.0}}]}
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [], lm: lm)
             |> Imp.call(%{question: "answer"})

    assert Imp.get(prediction, :answer) == "forced"
    assert prediction.metadata[:termination_reason] == :forced_submit
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
             Imp.react_v2(@submit_signature, [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :forced_submit

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
             Imp.react_v2(@submit_signature, [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :forced_submit

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
             Imp.react_v2(@submit_signature, [lookup],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :forced_submit

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
             Imp.react_v2(@submit_signature, [],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :max_iters
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
        required_returns_text: true,
        cache: false
      )

    lookup = Imp.tool(:lookup, "Look up a fact", fn _args -> "unused" end)

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [lookup],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :extracted
    assert prediction.metadata[:termination_cause] == :max_iters
    assert Map.keys(prediction.fields) |> Enum.sort() == [:answer, :confidence]

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
        required_returns_text: true,
        extraction_fails: true,
        cache: false
      )

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [],
               lm: lm,
               max_iters: 1,
               config: [json_retries: 0]
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert prediction.fields == %{}
    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :max_iters

    # Four requests, not five: the prose the required-only fallback returns is
    # read as a thought that called nothing, so no JSON-adapter re-ask fires.
    for _ <- 1..4 do
      assert_received {:required_only_tool_request, _messages, _opts}
    end

    refute_received {:required_only_tool_request, _messages, _opts}
  end

  test "normalizes atom- and string-keyed tool-call collection wrappers" do
    for wrapped <- [
          %{tool_calls: [%{name: "submit", arguments: %{answer: "atom", confidence: 1.0}}]},
          %{
            "tool_calls" => [
              %{
                "name" => "submit",
                "arguments" => %{"answer" => "string", "confidence" => 1.0}
              }
            ]
          },
          %{
            "tool_calls" => [
              %{
                "recipient_name" => "functions.submit",
                "parameters" => %{"answer" => "recipient", "confidence" => 1.0}
              }
            ]
          }
        ] do
      lm = action_lm([Imp.Prediction.new(%{tool_calls: wrapped})])

      assert {:ok, prediction} =
               Imp.react_v2(@submit_signature, [], lm: lm)
               |> Imp.call(%{question: "q"})

      assert Imp.get(prediction, :answer) in ["atom", "string", "recipient"]
      assert [event] = prediction.metadata[:history].messages

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
            "last words"
          ],
          parent
        )

      lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "observed" end)
      program = Imp.react_v2("question -> answer", [lookup], lm: lm, max_iters: 5)

      assert {:ok, prediction} =
               Imp.call(program, Map.put(%{question: "q"}, max_iters_key, 1))

      assert Imp.get(prediction, :answer) == "last words"
      assert prediction.metadata[:termination_reason] == :last_text
      assert prediction.metadata[:termination_cause] == :max_iters
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
             Imp.react_v2(@submit_signature, [], lm: lm, max_iters: 1)
             |> Imp.call(%{question: "q"})

    assert Imp.get(prediction, :answer) == nil
    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :max_iters
    assert %Imp.History{messages: [event]} = prediction.metadata[:history]

    assert [
             %{
               error: true,
               result: {:error, {:missing_output_fields, [:answer, :confidence]}}
             }
           ] =
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

    assert %Imp.History{messages: [event]} = incomplete.metadata[:history]

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

    assert %Imp.History{messages: [invalid_event]} = invalid.metadata[:history]

    assert [%{error: true, result: {:error, {:invalid_submit_outputs, _reason}}}] =
             invalid_event.tool_call_results
  end

  test "accepts serialized history and reserves submit" do
    assert_raise ArgumentError, ~r/submit is reserved/, fn ->
      submit = Imp.tool(:submit, "not allowed", & &1)
      Imp.react_v2("question -> answer", [submit])
    end

    history = %{"messages" => [%{"question" => "prior", "answer" => "prior answer"}]}
    lm = action_lm(["continued"])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm, max_iters: 0)
             |> Imp.call(%{question: "next", history: history})

    assert Imp.get(prediction, :answer) == "continued"
    assert prediction.metadata[:termination_reason] == :last_text
    assert %Imp.History{messages: [prior, current]} = prediction.metadata[:history]
    # A turn read back from JSON keeps the string keys it was stored with.
    assert prior["question"] == "prior"
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

  # A turn recorded while the loop still offered `submit` is replayed to a loop
  # that has none as what it was: the answer, in plain text. Shown as a call to
  # a tool the request does not offer, a model can imitate it and write the
  # raw tool-call markup as its answer.
  test "a recorded submit is replayed as the answer's text to a loop without submit" do
    submitted = fn thought, calls, results ->
      Imp.History.new([
        %{
          question: "prior",
          next_thought: thought,
          tool_calls: Imp.Adapter.Types.ToolCalls.new(calls) |> Imp.Redaction.redact(),
          tool_call_results: results
        }
      ])
    end

    no_submit = [guidance: %{finish_tool: nil, input_names: [], output_names: [], tool_names: []}]
    signature = Imp.react_v2("question -> answer", []).react.signature

    alone =
      submitted.(
        "",
        [%{id: "s-1", name: "submit", arguments: %{answer: "Seven, exactly."}}],
        [%{id: "s-1", name: "submit", result: "Completed.", error: false}]
      )

    assert [%{role: :system}, %{role: :user}, answer, %{role: :user}] =
             Imp.Adapter.Chat.format(signature, %{history: alone, tools: []}, no_submit)

    assert answer == %{role: :assistant, content: "Seven, exactly."}

    beside =
      submitted.(
        "checking",
        [
          %{id: "l-1", name: "lookup", arguments: %{query: "beam"}},
          %{id: "s-1", name: "submit", arguments: %{answer: "BEAM."}}
        ],
        [
          %{id: "l-1", name: "lookup", result: "BEAM", error: false},
          %{id: "s-1", name: "submit", result: "Completed.", error: false}
        ]
      )

    assert [
             %{role: :system},
             %{role: :user},
             %{role: :assistant, content: "checking", tool_calls: [call]},
             %{role: :tool, content: "BEAM"},
             %{role: :assistant, content: "BEAM."},
             %{role: :user}
           ] = Imp.Adapter.Chat.format(signature, %{history: beside, tools: []}, no_submit)

    assert call.function.name == "lookup"

    # A loop that still has submit replays the call as recorded.
    assert [
             %{role: :system},
             %{role: :user},
             %{tool_calls: [kept]},
             %{role: :tool},
             %{role: :user}
           ] =
             Imp.Adapter.Chat.format(signature, %{history: alone, tools: []}, [])

    assert kept.function.name == "submit"
  end

  # A submit the loop rejected was not the answer: the loop told the model so
  # and kept going. Replayed as text it would read as an answer the model gave
  # and then gave again. A call recorded without an id is matched to its result
  # by name, so the results of the step's other calls are kept.
  test "a rejected or id-less recorded submit is replayed only as what the loop accepted" do
    no_submit = [guidance: %{finish_tool: nil, input_names: [], output_names: [], tool_names: []}]
    signature = Imp.react_v2("question -> answer", []).react.signature

    step = fn fields, calls, results ->
      Map.merge(fields, %{
        tool_calls: Imp.Adapter.Types.ToolCalls.new(calls) |> Imp.Redaction.redact(),
        tool_call_results: results
      })
    end

    history =
      Imp.History.new([
        step.(
          %{question: "prior", next_thought: "trying"},
          [%{id: "s-1", name: "submit", arguments: %{reply: "wrong key"}}],
          [
            %{
              id: "s-1",
              name: "submit",
              result: {:error, {:missing_output_fields, [:answer]}},
              error: true
            }
          ]
        ),
        step.(
          %{next_thought: "again", answer: "Right key."},
          [%{id: "s-2", name: "submit", arguments: %{answer: "Right key."}}],
          [%{id: "s-2", name: "submit", result: %{answer: "Right key."}, error: false}]
        )
      ])
      |> Imp.History.dump()
      |> Imp.History.load()

    messages = Imp.Adapter.Chat.format(signature, %{history: history, tools: []}, no_submit)

    assert [
             %{role: :system},
             %{role: :user},
             %{role: :assistant, content: "trying"},
             %{role: :assistant, content: "again\n\nRight key."},
             %{role: :user}
           ] = messages

    refute Enum.any?(messages, &String.contains?(inspect(&1), "wrong key"))

    idless =
      Imp.History.new([
        step.(
          %{question: "prior", next_thought: ""},
          [
            %{name: "lookup", arguments: %{query: "beam"}},
            %{name: "submit", arguments: %{answer: "BEAM."}}
          ],
          [
            %{name: "lookup", result: "BEAM", error: false},
            %{name: "submit", result: %{answer: "BEAM."}, error: false}
          ]
        )
      ])

    assert [
             %{role: :system},
             %{role: :user},
             %{role: :assistant, tool_calls: [%{function: %{name: "lookup"}}]},
             %{role: :tool, content: "BEAM"},
             %{role: :assistant, content: "BEAM."},
             %{role: :user}
           ] = Imp.Adapter.Chat.format(signature, %{history: idless, tools: []}, no_submit)
  end

  # A host that renders input sections its own way gets the same rendering for
  # past turns as for the current one, whether or not the past turn called a
  # tool; otherwise the model reads its history in one format and its present
  # in another.
  test "a history turn with tool calls uses the host's input section renderer" do
    signature = Imp.react_v2("question -> answer", []).react.signature
    plain = fn _field, value -> value end

    history =
      Imp.History.new([
        %{
          question: "prior",
          next_thought: "",
          tool_calls:
            Imp.Adapter.Types.ToolCalls.new([
              %{id: "l-1", name: "lookup", arguments: %{query: "beam"}}
            ])
            |> Imp.Redaction.redact(),
          tool_call_results: [%{id: "l-1", name: "lookup", result: "BEAM", error: false}]
        }
      ])

    assert [
             %{role: :system},
             %{role: :user, content: past},
             %{role: :assistant},
             %{role: :tool},
             _
           ] =
             Imp.Adapter.Chat.format(
               signature,
               %{history: history, tools: []},
               input_section_renderer: plain
             )

    assert past == "prior"
  end

  test "participates in LM demo and registry-backed persistence lifecycle" do
    runner = fn %{"query" => query} -> query end
    registry = Imp.Saving.Registry.new(lookup_runner: runner)
    tool = Imp.tool(:lookup, "lookup", runner)
    demo = Imp.example(question: "demo", answer: "demo") |> Imp.with_inputs(:question)

    program =
      Imp.react_v2("question -> answer", [tool])
      |> Imp.with_demos([demo])
      |> Imp.dump(registry: registry)
      |> Imp.load(registry: registry)
      |> Imp.with_lm(action_lm(["ok"]))

    assert program.react.demos == [demo]
    assert {:ok, prediction} = Imp.call(program, %{question: "q"})
    assert Imp.get(prediction, :answer) == "ok"
  end

  # The model stopped calling tools and said its answer. The task declares one
  # text output for that prose to be, so the turn is over: one request, the
  # prose as the answer, and the prose recorded as that step's thought.
  test "a prose step with one text output ends the turn as the answer" do
    parent = self()
    prose = "I already know this one: Paris."
    lm = action_lm([prose], parent)
    lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "unused" end)

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [lookup], lm: lm)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == prose
    assert prediction.metadata[:termination_reason] == :answered

    messages = prediction.metadata[:history] |> Imp.History.messages()
    assert Enum.any?(messages, &(Map.get(&1, :next_thought) == prose))

    assert_received {:lm_call, _only_call}
    refute_received {:lm_call, _forced}
  end

  # A signature with more than one output cannot be filled from prose, so a
  # prose step still buys the forced submit there.
  test "a prose step with several outputs still forces submit" do
    parent = self()

    lm =
      action_lm(
        [
          "I already know this one.",
          %{tool_calls: [%{name: "submit", arguments: %{answer: "Paris", confidence: 0.9}}]}
        ],
        parent
      )

    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [%{name: :answer}, %{name: :confidence, type: :float}]
      })

    assert {:ok, prediction} =
             Imp.Predict.ReActV2.new(signature, [], lm: lm)
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert Imp.get(prediction, :confidence) == 0.9
    assert prediction.metadata[:termination_reason] == :forced_submit

    assert_received {:lm_call, _normal}
    assert_received {:lm_call, _forced}
  end

  # A signature with one text output has no `submit`: the roster the provider
  # is sent names only the user's tools, and the guidance says to answer in
  # plain text. A model that calls `submit` anyway is calling a tool that does
  # not exist, which is an observation like any other unknown tool.
  test "a signature with one text output is offered no submit tool" do
    parent = self()

    lm =
      action_lm(
        [
          %{tool_calls: [%{id: "s1", name: "submit", arguments: %{answer: "Paris"}}]},
          "Paris"
        ],
        parent
      )

    lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "unused" end)
    program = Imp.react_v2("question -> answer", [lookup], lm: lm)

    refute Map.has_key?(program.tools, :submit)
    assert program.react.adapter_opts[:guidance].finish_tool == nil

    assert {:ok, prediction} = Imp.call(program, %{question: "Capital of France?"})
    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :answered

    assert %Imp.History{messages: [first, second]} = prediction.metadata[:history]
    assert [%{error: true, result: {:error, {:unknown_tool, "submit"}}}] = first.tool_call_results
    # The answered step's event carries the output, as a submit's event does.
    assert second.answer == "Paris"

    assert_received {:lm_call, opts}
    assert Enum.map(opts[:tools], & &1.function.name) == ["lookup"]

    # With several outputs the same roster carries `submit`.
    submit_program = Imp.react_v2(@submit_signature, [lookup])
    assert Map.has_key?(submit_program.tools, :submit)
    assert submit_program.react.adapter_opts[:guidance].finish_tool == :submit
  end

  # A terminal tool ends the turn with the outputs it carries, the shape
  # Pydantic AI calls an output tool: the call is executed and recorded, and
  # what the host makes of it is the run's answer.
  test "finish_on ends the run on a tool call and records the call" do
    parent = self()
    reply = Imp.tool(:reply, "reply", fn %{"text" => text} -> "sent: #{text}" end)

    lm =
      action_lm(
        [
          %{
            next_thought: "answering",
            tool_calls: [%{id: "r1", name: "reply", arguments: %{"text" => "Paris"}}]
          }
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [reply],
               lm: lm,
               finish_on: %{
                 reply: fn arguments, _result, _inputs ->
                   {:finish, %{answer: arguments["text"]}}
                 end
               }
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :finished_by_tool
    assert prediction.metadata[:finished_by_tool] == "reply"

    assert %Imp.History{messages: [event]} = prediction.metadata[:history]

    assert [%{id: "r1", name: "reply", result: "sent: Paris", error: false}] =
             event.tool_call_results

    assert_received {:lm_call, _only_call}
    refute_received {:lm_call, _second}
  end

  test "finish_on returning :continue leaves the loop running" do
    parent = self()
    reply = Imp.tool(:reply, "reply", fn _arguments -> "sent" end)

    lm =
      action_lm(
        [
          %{tool_calls: [%{id: "r1", name: "reply", arguments: %{"text" => "wait"}}]},
          "Paris"
        ],
        parent
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [reply],
               lm: lm,
               finish_on: %{"reply" => fn _arguments, _result, _inputs -> :continue end}
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :answered
    assert %Imp.History{messages: [first, _second]} = prediction.metadata[:history]
    assert [%{name: "reply", error: false}] = first.tool_call_results
  end

  # Outputs a terminal tool cannot satisfy are the error an invalid submit is,
  # recorded as that call's result, and the loop goes on.
  test "finish_on outputs that miss a field are an error like an invalid submit" do
    reply = Imp.tool(:reply, "reply", fn _arguments -> "sent" end)

    lm =
      action_lm([
        %{tool_calls: [%{id: "r1", name: "reply", arguments: %{}}]},
        "Paris"
      ])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [reply],
               lm: lm,
               finish_on: %{reply: fn _arguments, _result, _inputs -> {:finish, %{}} end}
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :answered

    assert %Imp.History{messages: [first, _second]} = prediction.metadata[:history]

    assert [%{error: true, result: {:error, {:missing_output_fields, [:answer]}}}] =
             first.tool_call_results
  end

  test "finish_on sees the task inputs and rejects a name that is not a tool" do
    parent = self()
    reply = Imp.tool(:reply, "reply", fn _arguments -> "sent" end)

    lm = action_lm([%{tool_calls: [%{id: "r1", name: "reply", arguments: %{}}]}])

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [reply],
               lm: lm,
               finish_on: %{
                 reply: fn _arguments, _result, inputs ->
                   send(parent, {:finish_inputs, inputs})
                   {:finish, %{answer: "saw inputs"}}
                 end
               }
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "saw inputs"
    assert_received {:finish_inputs, %{question: "Capital of France?"}}

    assert_raise ArgumentError, ~r/:finish_on names no tool/, fn ->
      Imp.react_v2("question -> answer", [reply],
        finish_on: %{nope: fn _a, _r, _i -> :continue end}
      )
    end

    assert_raise ArgumentError, ~r/submit already ends the turn/, fn ->
      Imp.react_v2(@submit_signature, [reply],
        finish_on: %{submit: fn _a, _r, _i -> :continue end}
      )
    end
  end

  # What a model writes when it spells a tool call out as JSON rather than
  # calling natively. `Imp.Adapter.Types.ToolCall.from_map/1` reads it as one
  # call instead of an unexecutable malformed observation.
  test "a tool call written with the tool/args keys is executed" do
    parent = self()
    reply = Imp.tool(:reply, "reply", fn arguments -> send(parent, {:replied, arguments}) end)

    for call <- [
          %{"tool" => "reply", "arguments" => %{"text" => "hello"}},
          %{"tool" => "reply", "args" => %{"text" => "hello"}},
          %{tool: :reply, arguments: %{text: "hello"}}
        ] do
      lm =
        action_lm([
          %{tool_calls: [call]},
          "done"
        ])

      assert {:ok, prediction} =
               Imp.react_v2("question -> answer", [reply], lm: lm)
               |> Imp.call(%{question: "say hello"})

      assert Imp.get(prediction, :answer) == "done"
      assert_received {:replied, %{"text" => "hello"}}
    end
  end

  # A field's description is part of the contract. The submit tool's parameter
  # schema is where it reaches a provider that is sent tools natively, and the
  # only place it reaches a host that replaces the adapter's system section.
  test "the submit tool schema carries each output field's description" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [
          %{name: :answer, desc: "One sentence, no citation."},
          %{name: :confidence, type: :float}
        ]
      })

    lm =
      action_lm([%{tool_calls: [%{name: "submit", arguments: %{answer: "a", confidence: 1.0}}]}])

    program = Imp.react_v2(signature, [], lm: lm)
    submit = Enum.find(program.react.config[:tools], &(&1.function.name == "submit"))
    properties = submit.function.parameters["properties"]

    assert properties["answer"]["description"] == "One sentence, no citation."
    refute Map.has_key?(properties["confidence"], "description")
  end

  # Recording the thought is only half of it: the forced request has to show it
  # back, or the model is asked to submit without seeing what it just said.
  test "a prose-only step is an assistant turn in the forced request" do
    owner = self()
    prose = "I already know this one, no lookup needed."
    {:ok, state} = Agent.start_link(fn -> :first end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:request, messages})

          Agent.get_and_update(state, fn
            :first ->
              {prose, :second}

            :second ->
              {%{tool_calls: [%{name: "submit", arguments: %{answer: "Paris", confidence: 1.0}}]},
               :done}
          end)
        end
      )

    lookup = Imp.tool(:lookup, "lookup", fn _arguments -> "unused" end)

    assert {:ok, prediction} =
             Imp.react_v2(@submit_signature, [lookup],
               lm: lm,
               last_request_note: "Submit now."
             )
             |> Imp.call(%{question: "Capital of France?"})

    assert Imp.get(prediction, :answer) == "Paris"

    assert_received {:request, _first}
    assert_received {:request, forced}

    roles_and_contents = Enum.map(forced, &{&1[:role], to_string(&1[:content])})

    assert {:assistant, prose} in roles_and_contents

    thought_at = Enum.find_index(roles_and_contents, &(&1 == {:assistant, prose}))

    inputs_at =
      Enum.find_index(roles_and_contents, fn {role, c} ->
        role == :user and c =~ "Capital of France?"
      end)

    notice_at =
      Enum.find_index(roles_and_contents, fn {role, c} -> role == :user and c =~ "Submit now." end)

    assert inputs_at < thought_at
    assert thought_at < notice_at
  end

  test "a prose-only turn in prior history renders as an assistant message" do
    history =
      Imp.History.new([
        %{
          question: "Earlier?",
          next_thought: "Thinking out loud.",
          tool_calls: [],
          tool_call_results: []
        }
      ])

    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:request, messages})
          "ok"
        end
      )

    assert {:ok, prediction} =
             Imp.react_v2("question -> answer", [], lm: lm)
             |> Imp.call(%{question: "Now?", history: history})

    assert Imp.get(prediction, :answer) == "ok"
    assert_received {:request, messages}

    assert Enum.any?(
             messages,
             &(&1[:role] == :assistant and to_string(&1[:content]) == "Thinking out loud.")
           )
  end

  test "a forced submit that fails after the deadline has passed is cut short by the deadline" do
    counter = :counters.new(1, [])

    # The deadline passes during the first step's tool call; the forced
    # submit that follows fails.
    slow_lookup =
      Imp.tool(:lookup, "Look something up", fn _arguments ->
        Process.sleep(20)
        "found"
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            %{
              next_thought: "look first",
              tool_calls: [%{id: "c1", name: "lookup", arguments: %{}}]
            }
          else
            raise "provider timed out"
          end
        end
      )

    program = Imp.react_v2(@submit_signature, [slow_lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} =
             Imp.Deadline.with_deadline(10, fn ->
               Imp.call(program, %{question: "Capital of France?"})
             end)

    # The same answer the one-text-output path gives: what left the turn
    # without an answer is the deadline, not the step limit before it.
    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :deadline_exceeded
  end

  # Submit arguments have string keys, while a string signature names a field
  # by an atom when the atom exists (`team`) and by a string when it does not.
  # Submit finds both by their text.
  test "submit finds outputs named by atoms and by strings" do
    name = "contact_" <> Integer.to_string(System.unique_integer([:positive]))
    signature = Imp.signature("ticket -> team, " <> name)
    assert Enum.any?(signature.outputs, &(&1.name == name))
    assert Enum.any?(signature.outputs, &(&1.name == :team))

    lm =
      action_lm([
        %{tool_calls: [%{name: "submit", arguments: %{"team" => "atlas", name => "Maya"}}]}
      ])

    assert {:ok, prediction} =
             Imp.react_v2(signature, [], lm: lm, max_iters: 1) |> Imp.call(%{ticket: "t"})

    assert prediction.metadata[:termination_reason] == :submit
    assert Imp.get(prediction, :team) == "atlas"
    assert Imp.get(prediction, name) == "Maya"
  end

  # The text answer is for one unconstrained text output. An enum is a string
  # the model can get wrong, so it is filled through submit, whose schema
  # carries the allowed values.
  test "an enum output keeps submit, and text it rejects is not a complete answer" do
    parent = self()
    lm = action_lm([%{next_thought: "team: harbor", tool_calls: []}], parent)

    assert {:ok, prediction} =
             Imp.react_v2("ticket -> team: enum[atlas, harbor]", [], lm: lm, max_iters: 2)
             |> Imp.call(%{ticket: "t"})

    assert_received {:lm_call, opts}
    submit = Enum.find(opts[:tools] || [], &(&1.function.name == "submit"))
    assert submit.function.parameters["properties"]["team"]["enum"] == ["atlas", "harbor"]

    # The step wrote text instead of calling submit, and the forced submit and
    # the extraction after it got the same text, which the enum rejects.
    assert prediction.metadata[:termination_reason] == :incomplete
    assert prediction.metadata[:termination_cause] == :empty_tool_calls
    refute Imp.Prediction.complete?(prediction)
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
