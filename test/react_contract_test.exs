defmodule ReActContractTest do
  use ExUnit.Case, async: true

  test "submit must provide required signature outputs" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :submit, arguments: %{extra: "only"}}]}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:answer]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "empty tool calls cannot bypass required output validation" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: []}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, %Imp.AdapterParseError{kind: :missing_fields, reason: [:answer]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "provider-native mode forces its reserved submit after an empty action" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          turn = Agent.get_and_update(calls, &{&1, &1 + 1})

          case turn do
            0 ->
              assert Keyword.get(opts, :tool_choice) == "auto"
              %{tool_calls: []}

            1 ->
              assert Keyword.get(opts, :tool_choice) == %{type: "tool", name: "submit"}
              %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
          end
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert prediction.metadata[:termination_reason] == :forced_submit
    assert prediction.metadata[:termination_cause] == :empty_tool_calls
    assert [%{tool: :submit}] = prediction.metadata[:history]
  end

  test "max iteration exhaustion is an error with trace history" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "observed"}]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "zero max_iters fails before calling the model" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(parent, :react_lm_called)
          %{tool_calls: []}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 0)

    assert {:error, {:react_max_iters, []}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})

    refute_received :react_lm_called
  end

  test "invocation-local max_iters overrides the constructor budget without reaching the LM inputs" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:react_messages, messages})
          %{tool_calls: [%{name: :lookup, arguments: %{}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 4)

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "observed"}]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q", max_iters: 1})

    assert_receive {:react_messages, messages}
    refute inspect(messages) =~ "max_iters"
    refute_received {:react_messages, _messages}
  end

  test "invocation-local max_iters is validated before calling the model" do
    parent = self()

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> send(parent, :react_lm_called) end)

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm)

    assert {:error, {:invalid_react_max_iters, "1"}} =
             Imp.Predict.ReAct.call(agent, %{"max_iters" => "1", question: "q"})

    refute_received :react_lm_called
  end

  test "constructor and call boundaries report invalid inputs clearly" do
    assert_raise ArgumentError, ~r/Imp\.Predict\.ReAct\.new\/3: expected keyword options/, fn ->
      Imp.Predict.ReAct.new("question -> answer", [], %{lm: nil})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ReAct\.new\/3 expects tools to be a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.ReAct.new("question -> answer", :not_tools)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ReAct\.new\/3 expects tools to be a list of Imp\.Tool structs/,
                 fn ->
                   Imp.Predict.ReAct.new("question -> answer", [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ReAct\.new\/3: invalid value for :max_iters option: expected non negative integer/,
                 fn ->
                   Imp.Predict.ReAct.new("question -> answer", [], max_iters: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Predict\.ReAct\.new\/3: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   Imp.Predict.ReAct.new("question -> answer", [], tool_policy: %{only: :lookup})
                 end

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: nil)

    assert {:error, {:invalid_react_inputs, message}} =
             Imp.Predict.ReAct.call(agent, :not_inputs)

    assert message =~ "expected a map or keyword/list of input pairs"

    assert {:error, {:invalid_react_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.Predict.ReAct.call(agent, [:not_a_pair])
  end

  test "tool policy denial stops ReAct before executing LM-selected tool" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "secret"}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> raise "should not run" end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, tool_policy: [])

    assert {:error, {:tool_authorization_denied, :lookup, :tool_policy}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "unknown LM-selected tools fail immediately instead of spinning to max iterations" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: "external_tool", arguments: %{query: "x"}}]}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 3)

    assert {:error, {:unknown_tool, "external_tool"}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "malformed provider tool calls become structured ReAct errors" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: ["not-a-tool-call"]}
        end
      )

    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: lm, max_iters: 1)

    assert {:error, {:malformed_tool_call, "not-a-tool-call"}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "provider JSON string tool arguments are decoded before execution" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: ~s({"query":"capital"})}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> %{answer: "Paris"} end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:error,
            {:react_max_iters,
             [%{tool: :lookup, arguments: %{query: "capital"}, result: %{answer: "Paris"}}]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "OpenAI-style nested function tool calls are normalized before execution" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{
                id: "call_lookup",
                type: "function",
                function: %{
                  name: "lookup",
                  arguments: ~s({"query":"capital"})
                }
              },
              %{
                id: "call_submit",
                type: "function",
                function: %{
                  name: "submit",
                  arguments: ~s({"answer":"Paris"})
                }
              }
            ]
          }
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> "Paris" end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 1)

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "Paris"

    assert [
             %{tool: :lookup, arguments: %{query: "capital"}, result: "Paris"},
             %{tool: :submit, arguments: %{answer: "Paris"}, result: %{answer: "Paris"}}
           ] = prediction.metadata[:history]
  end

  test "tool argument normalization keeps unknown provider keys as strings" do
    unknown_key = "model_generated_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    assert %{^unknown_key => "kept", query: "capital"} =
             Imp.Tool.normalize_arguments(%{"query" => "capital", unknown_key => "kept"})

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end

  test "string tool policies authorize normalized ReAct tool names" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: "lookup", arguments: %{query: "capital"}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: "capital"} -> "Paris" end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        max_iters: 1,
        tool_policy: ["lookup"]
      )

    assert {:error, {:react_max_iters, [%{tool: :lookup, result: "Paris"}]}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "tool exceptions become structured ReAct errors" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "x"}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> raise "provider exploded" end)
    agent = Imp.Predict.ReAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)

    assert {:error, {:tool_error, :lookup, %RuntimeError{message: "provider exploded"}}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "tool policy exceptions become structured ReAct errors" do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{tool_calls: [%{name: :lookup, arguments: %{query: "x"}}]}
        end
      )

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> "observed" end)
    policy = fn _name, _args -> raise "policy broke" end

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        tool_policy: policy,
        max_iters: 3
      )

    assert {:error, {:tool_policy_error, :lookup, %RuntimeError{message: "policy broke"}}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "submit short-circuits later provider tool calls" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            tool_calls: [
              %{name: :submit, arguments: %{answer: "done"}},
              %{name: :side_effect, arguments: %{}}
            ]
          }
        end
      )

    side_effect =
      Imp.Tool.new(:side_effect, "must not run after submit", fn _args ->
        send(parent, :side_effect_ran)
        "bad"
      end)

    agent = Imp.Predict.ReAct.new("question -> answer", [side_effect], lm: lm)

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "done"
    refute_received :side_effect_ran
    assert [%{tool: :submit}] = prediction.metadata[:history]
  end

  # ------------------------------------------------------------------
  # :dspy — byte-faithful port of DSPy 3.2.1 dspy.ReAct.
  #
  # In this mode the reasoning signature is (inputs + trajectory) ->
  # next_thought (str), next_tool_name (Literal[tools + 'finish']),
  # next_tool_args (dict[str, Any]). The model emits those three fields as
  # ORDINARY chat output — there are no provider tool_calls. Each turn the
  # observation is appended to a text trajectory; the reserved `finish` tool
  # terminates the loop; a separate dspy.ChainOfThought pass extracts the outputs
  # from (inputs + trajectory). These assertions encode what dspy/predict/
  # react.py actually does, verified byte-for-byte by the golden trace
  # (react_dspy_tool_lookup). The full-prompt byte-parity is locked in
  # golden_trace_test.exs; these tests lock the control-flow and shape.

  test "dspy: reasoning signature and instructions match dspy.ReAct" do
    lookup =
      Imp.Tool.new(:lookup, "Lookup a fact by query.", fn %{query: q} -> q end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    signature =
      Imp.signature("question -> answer", "Use the lookup tool when external facts are needed.")

    agent = Imp.Predict.ReAct.new(signature, [lookup], lm: nil, mode: :dspy)

    react = agent.react.signature

    # Inputs = original inputs + a `trajectory` (string) input (react.py line 75).
    assert Enum.map(react.inputs, & &1.name) == [:question, :trajectory]
    assert Enum.find(react.inputs, &(&1.name == :trajectory)).type == :string

    # Outputs = next_thought (str) + next_tool_name (Literal[...]) + next_tool_args
    # (dict) — react.py lines 76-78, in this order.
    assert Enum.map(react.outputs, & &1.name) == [:next_thought, :next_tool_name, :next_tool_args]
    next_tool_name = Enum.find(react.outputs, &(&1.name == :next_tool_name))

    # Literal enum is the user tool names, then the reserved `finish` LAST
    # (react.py adds finish to the tools dict before building the Literal).
    assert next_tool_name.metadata.constraints.enum == ["lookup", "finish"]
    assert Enum.find(react.outputs, &(&1.name == :next_tool_args)).type == :object

    # Instructions reproduce DSPy's "You are an Agent..." block, list each tool
    # textually via str(Tool), and end with the JSON-format reminder (react.py
    # lines 51-71). The reserved finish tool references the output fields.
    instr = react.instructions
    assert instr =~ "Use the lookup tool when external facts are needed."
    assert instr =~ "You are an Agent. In each episode, you will be given the fields `question`"
    assert instr =~ "for producing `answer`"

    assert instr =~
             "(1) lookup, whose description is <desc>Lookup a fact by query.</desc>. " <>
               "It takes arguments {\"query\": {\"type\": \"string\"}}."

    assert instr =~ "(2) finish, whose description is <desc>Marks the task as complete."

    assert instr =~
             "i.e. `answer`, are now available to be extracted.</desc>. It takes arguments {}."

    assert instr =~
             "When providing `next_tool_args`, the value inside the field must be in JSON format"

    # No provider tool config is attached — the loop is chat-field driven.
    refute Keyword.has_key?(agent.react.config, :tools)
    refute Keyword.has_key?(agent.react.config, :tool_choice)
    # The reserved tool is `finish` (not `submit`).
    assert Map.has_key?(agent.tools, :finish)
    refute Map.has_key?(agent.tools, :submit)
  end

  test "dspy: interleaves the text trajectory then extracts after finish" do
    parent = self()

    Process.put(:react_actions, [
      %{
        next_thought: "Need the lookup result.",
        next_tool_name: "lookup",
        next_tool_args: %{"query" => "capital-france"}
      },
      %{
        next_thought: "The lookup result is enough.",
        next_tool_name: "finish",
        next_tool_args: %{}
      },
      %{reasoning: "The lookup observation says Paris.", answer: "Paris"}
    ])

    lm =
      Imp.Test.FunLM.new(fn messages, _opts ->
        send(parent, {:react_messages, messages})
        [next | rest] = Process.get(:react_actions)
        Process.put(:react_actions, rest)
        {:ok, next}
      end)

    lookup =
      Imp.Tool.new(:lookup, "Lookup a fact by query.", fn %{query: "capital-france"} ->
        "Paris"
      end)

    signature =
      Imp.signature("question -> answer", "Use the lookup tool when external facts are needed.")

    agent =
      Imp.Predict.ReAct.new(signature, [lookup],
        lm: lm,
        mode: :dspy,
        max_iters: 5
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})

    # Extraction (a separate ChainOfThought) yields reasoning + the outputs.
    assert Imp.Prediction.get(prediction, :answer) == "Paris"
    assert Imp.Prediction.get(prediction, :reasoning) == "The lookup observation says Paris."
    assert prediction.metadata[:termination_reason] == :finish
    refute Map.has_key?(prediction.metadata, :termination_cause)

    # History is derived from the trajectory: the real tool call, then finish.
    assert [
             %{tool: :lookup, arguments: %{query: "capital-france"}, result: "Paris"},
             %{tool: :finish, result: "Completed."}
           ] = prediction.metadata[:history]

    assert Process.get(:react_actions) == []

    # The SECOND reasoning call must see the first tool call rendered as the DSPy
    # text trajectory, with the tool args JSON-serialized the way DSPy does
    # (space after the colon, from json.dumps).
    _first = receive(do: ({:react_messages, m} -> m))
    second = receive(do: ({:react_messages, m} -> m))
    third = receive(do: ({:react_messages, m} -> m))
    second_user = second |> List.last() |> Map.fetch!(:content)
    assert second_user =~ "[[ ## trajectory ## ]]\n[[ ## thought_0 ## ]]\nNeed the lookup result."
    assert second_user =~ "[[ ## tool_name_0 ## ]]\nlookup"
    assert second_user =~ ~s([[ ## tool_args_0 ## ]]\n{"query": "capital-france"})
    assert second_user =~ "[[ ## observation_0 ## ]]\nParis"

    # The extraction call sees the finish observation too, and asks for the
    # ORIGINAL output field (answer) plus the CoT reasoning field.
    third_user = third |> List.last() |> Map.fetch!(:content)
    assert third_user =~ "[[ ## observation_1 ## ]]\nCompleted."
    assert third_user =~ "`[[ ## reasoning ## ]]`"
    assert third_user =~ "`[[ ## answer ## ]]`"
  end

  test "dspy: iteration exhaustion falls through to extraction" do
    Process.put(:react_actions, [
      %{next_thought: "look it up", next_tool_name: "lookup", next_tool_args: %{}},
      %{reasoning: "Use the observation", answer: "observed"}
    ])

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> "observed" end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy,
        max_iters: 1
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "observed"
    assert prediction.metadata[:termination_reason] == :extracted
    assert prediction.metadata[:termination_cause] == :max_iters
    assert [%{tool: :lookup, result: "observed"}] = prediction.metadata[:history]
  end

  test "dspy: truncates the oldest tool call but retains the remaining call" do
    Process.put(:react_context_responses, [
      {:ok,
       %{next_thought: "t", next_tool_name: "lookup", next_tool_args: %{"query" => "first"}}},
      {:ok,
       %{next_thought: "t", next_tool_name: "lookup", next_tool_args: %{"query" => "second"}}},
      {:error, %Imp.LMError{context_window_exceeded: true, message: "too long"}},
      {:error, %Imp.LMError{context_window_exceeded: true, message: "still too long"}},
      {:ok, %{next_thought: "t", next_tool_name: "finish", next_tool_args: %{}}},
      {:ok, %{reasoning: "The retained trajectory is enough", answer: "done"}}
    ])

    lm =
      Imp.Test.FunLM.new(fn messages, _opts ->
        [next | rest] = Process.get(:react_context_responses)
        Process.put(:react_context_responses, rest)
        send(self(), {:react_context_messages, messages})
        next
      end)

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: query} -> query end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy,
        max_iters: 3
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "done"
    # The first overflow drops the oldest call. DSPy then refuses to truncate
    # the one complete call that remains, so extraction and returned history
    # retain that useful observation.
    assert [%{tool: :lookup, arguments: %{query: "second"}, result: "second"}] =
             prediction.metadata[:history]

    assert Process.get(:react_context_responses) == []

    messages = for _ <- 1..6, do: receive(do: ({:react_context_messages, value} -> value))
    # Attempt 1 renders the full trajectory; the first truncation drops the
    # oldest tool call (4 keys), and later retries preserve the remaining call.
    assert inspect(Enum.at(messages, 2)) =~ "first"
    refute inspect(Enum.at(messages, 3)) =~ "first"
    assert inspect(Enum.at(messages, 3)) =~ "second"
    assert inspect(Enum.at(messages, 4)) =~ "second"
  end

  test "dspy: reports an overflow when no trajectory can be truncated" do
    error = %Imp.LMError{context_window_exceeded: true, message: "input alone is too long"}
    lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:error, error} end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [],
        lm: lm,
        mode: :dspy,
        max_iters: 1
      )

    assert {:error, {:react_trajectory_not_truncatable, ^error}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})
  end

  test "dspy: context recovery retains the only completed tool call" do
    Process.put(:react_single_call_context_responses, [
      {:ok,
       %{
         next_thought: "look it up",
         next_tool_name: "lookup",
         next_tool_args: %{"query" => "fact"}
       }},
      {:error, %Imp.LMError{context_window_exceeded: true, message: "too long"}},
      {:ok, %{reasoning: "Use the retained observation", answer: "fact"}}
    ])

    lm =
      Imp.Test.FunLM.new(fn messages, _opts ->
        [next | rest] = Process.get(:react_single_call_context_responses)
        Process.put(:react_single_call_context_responses, rest)
        send(self(), {:react_single_call_context_messages, messages})
        next
      end)

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: query} -> query end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy,
        max_iters: 2
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "fact"
    assert prediction.metadata[:termination_reason] == :extracted
    assert prediction.metadata[:termination_cause] == :parse_error

    assert [%{tool: :lookup, arguments: %{query: "fact"}, result: "fact"}] =
             prediction.metadata[:history]

    assert Process.get(:react_single_call_context_responses) == []

    messages =
      for _ <- 1..3,
          do: receive(do: ({:react_single_call_context_messages, value} -> value))

    assert inspect(Enum.at(messages, 1)) =~ "observation_0"
    assert inspect(Enum.at(messages, 2)) =~ "observation_0"
    assert inspect(Enum.at(messages, 2)) =~ "fact"
  end

  test "dspy: also truncates the extraction trajectory retries" do
    Process.put(:react_extraction_context_responses, [
      {:ok,
       %{next_thought: "t", next_tool_name: "lookup", next_tool_args: %{"query" => "first"}}},
      {:ok,
       %{next_thought: "t", next_tool_name: "lookup", next_tool_args: %{"query" => "second"}}},
      {:ok, %{next_thought: "t", next_tool_name: "finish", next_tool_args: %{}}},
      {:error, %Imp.LMError{context_window_exceeded: true, message: "too long"}},
      {:error, %Imp.LMError{context_window_exceeded: true, message: "still too long"}},
      {:ok, %{reasoning: "The retained trajectory is enough", answer: "done"}}
    ])

    lm =
      Imp.Test.FunLM.new(fn messages, _opts ->
        [next | rest] = Process.get(:react_extraction_context_responses)
        Process.put(:react_extraction_context_responses, rest)
        send(self(), {:react_extraction_context_messages, messages})
        next
      end)

    lookup = Imp.Tool.new(:lookup, "lookup", fn %{query: query} -> query end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy,
        max_iters: 3
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "done"
    assert [%{tool: :finish, result: "Completed."}] = prediction.metadata[:history]

    messages =
      for _ <- 1..6, do: receive(do: ({:react_extraction_context_messages, value} -> value))

    assert inspect(Enum.at(messages, 3)) =~ "first"
    refute inspect(Enum.at(messages, 4)) =~ "first"
    assert inspect(Enum.at(messages, 4)) =~ "second"
    refute inspect(Enum.at(messages, 5)) =~ "second"
  end

  test "dspy: tool exceptions become recoverable observations" do
    Process.put(:react_actions, [
      %{next_thought: "try lookup", next_tool_name: "lookup", next_tool_args: %{"query" => "x"}},
      %{next_thought: "done", next_tool_name: "finish", next_tool_args: %{}},
      %{reasoning: "The failed lookup is enough context", answer: "recovered"}
    ])

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> raise "provider exploded" end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy,
        max_iters: 3
      )

    # react.py wraps a raising tool call in try/except and stores
    # "Execution error in {tool}: ..." as the observation, so the model can
    # recover on a later turn. (Imp's message text stands in for DSPy's Python
    # traceback — see the release note.)
    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "recovered"

    assert [
             %{tool: :lookup, result: "Execution error in lookup: provider exploded"},
             %{tool: :finish, result: "Completed."}
           ] = prediction.metadata[:history]

    assert Process.get(:react_actions) == []
  end

  test "dspy: a tool returning an error tuple is a recoverable observation" do
    Process.put(:react_actions, [
      %{next_thought: "try lookup", next_tool_name: "lookup", next_tool_args: %{}},
      %{next_thought: "done", next_tool_name: "finish", next_tool_args: %{}},
      %{reasoning: "Recovered from the explicit error", answer: "done"}
    ])

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> {:error, :not_found} end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})

    assert [
             %{tool: :lookup, result: "Execution error in lookup: not found"},
             %{tool: :finish, result: "Completed."}
           ] = prediction.metadata[:history]
  end

  # DSPy's MCP boundary raises on an error result and ReAct shows the exception;
  # Imp keeps the envelope as a term, and the model reads the tool's own words.
  test "dspy: an MCP error result is observed as the tool's own words" do
    Process.put(:react_actions, [
      %{next_thought: "try lookup", next_tool_name: "lookup", next_tool_args: %{}},
      %{next_thought: "done", next_tool_name: "finish", next_tool_args: %{}},
      %{reasoning: "Recovered from the explicit error", answer: "done"}
    ])

    envelope = %{
      "isError" => true,
      "content" => [%{"type" => "text", "text" => "no record at that uri"}]
    }

    lookup =
      Imp.Tool.new(:lookup, "lookup", fn _args -> {:error, {:mcp_tool_error, envelope}} end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: sequence_lm(:react_actions),
        mode: :dspy
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})

    assert [
             %{tool: :lookup, result: "Execution error in lookup: no record at that uri"},
             %{tool: :finish, result: "Completed."}
           ] = prediction.metadata[:history]
  end

  test "dspy: an invalid/missing action is a parse failure that extracts" do
    # react.py breaks the loop on a reasoning-signature ValueError (an action it
    # cannot parse) and proceeds straight to extraction. Here the model omits
    # next_tool_name/next_tool_args, so the reasoning signature cannot be parsed.
    # (JSON adapter so a missing-field parse failure is not masked by the chat
    # adapter's JSON fallback retry.)
    Process.put(:react_actions, [
      %{next_thought: "I cannot select an action"},
      %{reasoning: "Answer without another action", answer: "fallback"}
    ])

    agent =
      Imp.Predict.ReAct.new("question -> answer", [],
        lm: sequence_lm(:react_actions),
        adapter: Imp.Adapter.JSON,
        mode: :dspy,
        max_iters: 2
      )

    assert {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "fallback"
    assert prediction.metadata[:termination_reason] == :extracted
    assert prediction.metadata[:termination_cause] == :parse_error
    # Nothing was appended to the trajectory before the failed action.
    assert prediction.metadata[:history] == []
  end

  test "dspy: tool policy stays fail-fast (Imp safety extension)" do
    parent = self()

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        send(parent, :react_lm_called)
        {:ok, %{next_thought: "look", next_tool_name: "lookup", next_tool_args: %{}}}
      end)

    lookup = Imp.Tool.new(:lookup, "lookup", fn _args -> raise "must not execute" end)

    agent =
      Imp.Predict.ReAct.new("question -> answer", [lookup],
        lm: lm,
        mode: :dspy,
        tool_policy: []
      )

    # DSPy has no tool policy; this is an Imp safety layer. A denied tool is NOT
    # fed back to the model as a recoverable observation — it fails fast.
    assert {:error, {:tool_authorization_denied, :lookup, :tool_policy}} =
             Imp.Predict.ReAct.call(agent, %{question: "q"})

    assert_received :react_lm_called
    refute_received :react_lm_called
  end

  test "ReAct mode defaults honestly to the existing provider-native contract" do
    agent = Imp.Predict.ReAct.new("question -> answer", [], lm: nil)
    assert agent.mode == :provider_native

    assert_raise ArgumentError, ~r/expected one of \[:provider_native, :dspy\]/, fn ->
      Imp.Predict.ReAct.new("question -> answer", [], mode: :source_faithful)
    end
  end

  defp sequence_lm(key) do
    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        [next | rest] = Process.get(key)
        Process.put(key, rest)
        next
      end
    )
  end
end
