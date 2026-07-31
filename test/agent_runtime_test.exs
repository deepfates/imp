defmodule AgentRuntimeTest do
  use ExUnit.Case, async: true

  alias Imp.Agent
  alias Imp.Agent.Runtime

  test "agent forwards typed inputs through tools and child agents with trace capture" do
    normalize =
      Imp.Tool.new(:normalize, "normalize text", fn %{text: text} ->
        String.downcase(text)
      end)

    child =
      Agent.new(
        :child,
        fn %{text: text}, runtime ->
          {:ok, %{label: String.upcase(text)}, runtime}
        end,
        input_schema: %{required: [:text]},
        output_schema: %{required: [:label]}
      )

    agent =
      Agent.new(
        :parent,
        fn %{text: text}, runtime ->
          {:ok, normalized, runtime} =
            Agent.call_tool(agent_ref(), :normalize, %{text: text}, runtime)

          Agent.call_child(agent_ref(), :child, %{text: normalized}, runtime)
        end,
        tools: [normalize],
        children: [child],
        input_schema: %{required: [:text]},
        output_schema: %{required: [:label]}
      )

    Process.put(:agent_ref, agent)

    assert {:ok, %{label: "HELLO"}, runtime} = Agent.run(agent, %{text: "HeLLo"})
    assert Enum.map(runtime.traces, & &1.type) == [:tool, :agent, :agent]
  after
    Process.delete(:agent_ref)
  end

  test "tool constructor reports invalid definitions clearly" do
    assert_raise ArgumentError, ~r/Imp\.Tool names must be atoms or strings/, fn ->
      Imp.Tool.new(123, "bad", fn input -> input end)
    end

    assert_raise ArgumentError, ~r/Imp\.Tool\.new\/4 expects a unary function/, fn ->
      Imp.Tool.new(:bad, "bad", :not_a_function)
    end

    assert_raise ArgumentError, ~r/Imp\.Tool\.new\/4.*expected keyword options/, fn ->
      Imp.Tool.new(:bad, "bad", fn input -> input end, :not_options)
    end

    assert_raise ArgumentError, ~r/Imp\.Tool\.new\/4.*:schema.*expected.*map/s, fn ->
      Imp.Tool.new(:bad, "bad", fn input -> input end, schema: :not_a_schema)
    end
  end

  test "agent constructor reports invalid definitions clearly" do
    handler = fn input, runtime -> {:ok, input, runtime} end
    child = Agent.new(:child, handler)

    assert {:ok, [^child]} = Agent.validate_children([child])
    assert {:error, message} = Agent.validate_children([:not_an_agent])
    assert message =~ "expected a list of Imp.Agent structs"

    assert_raise ArgumentError, ~r/Imp\.Agent names must be atoms or strings/, fn ->
      Agent.new(123, handler)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.new\/3 expects an arity-2 or arity-3 handler/,
                 fn ->
                   Agent.new(:bad, fn input -> input end)
                 end

    assert_raise ArgumentError, ~r/Imp\.Agent\.new\/3.*expected keyword options/, fn ->
      Agent.new(:bad, handler, :not_options)
    end

    assert_raise ArgumentError, ~r/Imp\.Agent\.new\/3.*:input_schema.*expected.*map/s, fn ->
      Agent.new(:bad, handler, input_schema: :not_schema)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.new\/3: invalid value for :tools option: expected a list of Imp\.Tool structs/,
                 fn ->
                   Agent.new(:bad, handler, tools: [:not_a_tool])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.new\/3: invalid value for :children option: expected a list of Imp\.Agent structs/,
                 fn ->
                   Agent.new(:bad, handler, children: [:not_an_agent])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.new\/3: invalid value for :tool_policy option: expected :allow, an atom\/string tool name, a list of tool names, or an arity-2 function/,
                 fn ->
                   Agent.new(:bad, handler, tool_policy: %{allow: [:lookup]})
                 end
  end

  test "runtime stores large context by reference and exposes memory" do
    runtime =
      Runtime.new()
      |> Runtime.put_context(:document, String.duplicate("important ", 200))
      |> Runtime.put_memory(:seen, 1)

    assert {:ok, ref} = Runtime.context_ref(runtime, :document)

    agent =
      Agent.new(:reader, fn %{doc: doc}, runtime ->
        {:ok, %{length: String.length(doc), seen: runtime.memory.seen}, runtime}
      end)

    assert {:ok, %{length: length, seen: 1}, _runtime} = Agent.run(agent, %{doc: ref}, runtime)
    assert length > 1000
  end

  test "runtime constructor reports invalid options clearly" do
    assert_raise ArgumentError, ~r/Imp\.Agent\.Runtime\.new\/1: expected keyword options/, fn ->
      Runtime.new(%{context: %{}})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.Runtime\.new\/1: invalid value for :context/,
                 fn ->
                   Runtime.new(context: [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.Runtime\.new\/1: invalid value for :event_sink option: expected nil or an arity-1 function/,
                 fn ->
                   Runtime.new(event_sink: fn _event, _runtime -> :ok end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Agent\.Runtime\.new\/1: invalid value for :redact_keys option: expected a list of atom or string key names/,
                 fn ->
                   Runtime.new(redact_keys: [:api_key, 123])
                 end
  end

  test "arity-3 handlers receive the agent without process dictionary self-reference" do
    normalize =
      Imp.Tool.new(:normalize, "normalize text", fn %{text: text} ->
        String.downcase(text)
      end)

    agent =
      Agent.new(
        :parent,
        fn agent, %{text: text}, runtime ->
          Agent.call_tool(agent, :normalize, %{text: text}, runtime)
        end,
        tools: [normalize]
      )

    assert {:ok, "hello", runtime} = Agent.run(agent, %{text: "HeLLo"})
    assert [%{type: :tool, tool: :normalize}, %{type: :agent, agent: :parent}] = runtime.traces
  end

  test "tool policy can deny tool execution with a structured trace" do
    boom = Imp.Tool.new(:boom, "blocked", fn _ -> raise "should not run" end)

    agent =
      Agent.new(
        :locked,
        fn agent, _input, runtime -> Agent.call_tool(agent, :boom, %{}, runtime) end,
        tools: [boom],
        tool_policy: []
      )

    assert {:error, {:tool_denied, :boom}, runtime} = Agent.run(agent, %{})

    assert [%{type: :tool_denied, tool: :boom}, %{type: :agent_error, agent: :locked}] =
             runtime.traces
  end

  test "tool policy accepts string tool names consistently" do
    tool = Imp.Tool.new(:lookup, "lookup", fn _input -> "ok" end)

    agent =
      Agent.new(
        :reader,
        fn agent, _input, runtime -> Agent.call_tool(agent, :lookup, %{}, runtime) end,
        tools: [tool],
        tool_policy: ["lookup"]
      )

    assert {:ok, "ok", _runtime} = Agent.run(agent, %{})
  end

  test "tool policy exceptions become structured agent errors" do
    tool = Imp.Tool.new(:lookup, "lookup", fn _input -> "should not run" end)

    agent =
      Agent.new(
        :locked,
        fn agent, _input, runtime -> Agent.call_tool(agent, :lookup, %{}, runtime) end,
        tools: [tool],
        tool_policy: fn _name, _input -> raise "policy exploded" end
      )

    assert {:error, {:tool_policy_error, :lookup, "policy exploded"}, runtime} =
             Agent.run(agent, %{})

    assert [
             %{
               type: :tool_denied,
               tool: :lookup,
               error: {:tool_policy_error, :lookup, "policy exploded"}
             },
             %{type: :agent_error, agent: :locked}
           ] = runtime.traces
  end

  test "handler exceptions become structured agent errors" do
    agent =
      Agent.new(:boom, fn _input, _runtime ->
        raise "handler exploded"
      end)

    assert {:error, {:handler_error, :boom, "handler exploded"}, runtime} =
             Agent.run(agent, %{})

    assert [
             %{
               type: :agent_error,
               agent: :boom,
               error: {:handler_error, :boom, "handler exploded"}
             }
           ] =
             runtime.traces
  end

  test "agent handlers, tools, and policies preserve typed operational safety" do
    handler_safety =
      Imp.OperationalSafetyError.exception(kind: :cancellation, reason: :operator_stop)

    handler =
      Agent.new(:guarded_handler, fn _input, _runtime ->
        raise handler_safety
      end)

    assert {:error, ^handler_safety, _runtime} = Agent.run(handler, %{})

    tool_safety = Imp.OperationalSafetyError.exception(kind: :cost, reason: :tool_limit)
    tool = Imp.Tool.new(:guarded_tool, "guarded", fn _input -> raise tool_safety end)

    tool_agent =
      Agent.new(
        :tool_agent,
        fn agent, _input, runtime -> Agent.call_tool(agent, :guarded_tool, %{}, runtime) end,
        tools: [tool]
      )

    assert {:error, ^tool_safety, _runtime} = Agent.run(tool_agent, %{})

    policy_safety = Imp.OperationalSafetyError.exception(kind: :route, reason: :tool_route)
    policy_tool = Imp.Tool.new(:lookup, "lookup", fn _input -> :unused end)

    policy_agent =
      Agent.new(
        :policy_agent,
        fn agent, _input, runtime -> Agent.call_tool(agent, :lookup, %{}, runtime) end,
        tools: [policy_tool],
        tool_policy: fn _name, _input -> raise policy_safety end
      )

    assert {:error, ^policy_safety, _runtime} = Agent.run(policy_agent, %{})
  end

  test "invalid handler return shapes become structured agent errors" do
    agent = Agent.new(:bad_return, fn _input, _runtime -> :ok end)

    assert {:error, {:invalid_handler_result, :bad_return, :ok}, runtime} =
             Agent.run(agent, %{})

    assert [
             %{
               type: :agent_error,
               agent: :bad_return,
               error: {:invalid_handler_result, :bad_return, :ok}
             }
           ] = runtime.traces
  end

  test "output schema failures preserve traces accumulated by the handler" do
    tool = Imp.Tool.new(:normalize, "normalize", fn %{text: text} -> String.downcase(text) end)

    agent =
      Agent.new(
        :schema_checked,
        fn agent, %{text: text}, runtime ->
          {:ok, _output, runtime} = Agent.call_tool(agent, :normalize, %{text: text}, runtime)
          {:ok, %{wrong: true}, runtime}
        end,
        tools: [tool],
        output_schema: %{required: [:label]}
      )

    assert {:error, {:missing_required, [:label]}, runtime} =
             Agent.run(agent, %{text: "HELLO"})

    assert [
             %{type: :tool, tool: :normalize, output: "hello"},
             %{type: :agent_error, agent: :schema_checked, error: {:missing_required, [:label]}}
           ] = runtime.traces
  end

  test "schema validation reports non-map outputs instead of crashing" do
    agent =
      Agent.new(:bad_output, fn _input, runtime -> {:ok, :not_a_map, runtime} end,
        output_schema: %{required: [:label]}
      )

    assert {:error, {:invalid_schema_value, ":not_a_map"}, runtime} =
             Agent.run(agent, %{})

    assert [
             %{
               type: :agent_error,
               agent: :bad_output,
               error: {:invalid_schema_value, ":not_a_map"}
             }
           ] = runtime.traces
  end

  test "stream_events reports handler failures as structured error events" do
    agent =
      Agent.new(:boom, fn _inputs, _runtime ->
        raise "stream worker exploded"
      end)

    assert [
             %{
               type: :trace,
               event: %{
                 type: :agent_error,
                 agent: :boom,
                 error: {:handler_error, :boom, "stream worker exploded"}
               }
             },
             %{
               type: :error,
               error: {:handler_error, :boom, "stream worker exploded"},
               traces: [%{type: :agent_error, agent: :boom}]
             }
           ] =
             agent
             |> Agent.stream_events(%{})
             |> Enum.to_list()
  end

  test "runtime redacts sensitive trace keys" do
    echo = Imp.Tool.new(:echo, "echo", fn input -> input end)

    agent =
      Agent.new(
        :redactor,
        fn agent, _input, runtime ->
          Agent.call_tool(
            agent,
            :echo,
            %{api_key: "sk-live", nested: %{token: "secret"}},
            runtime
          )
        end,
        tools: [echo]
      )

    assert {:ok, _output, runtime} = Agent.run(agent, %{})

    assert [
             %{
               input: %{api_key: "[REDACTED]", nested: %{token: "[REDACTED]"}},
               output: %{api_key: "[REDACTED]", nested: %{token: "[REDACTED]"}}
             },
             %{output: %{api_key: "[REDACTED]", nested: %{token: "[REDACTED]"}}}
           ] = runtime.traces
  end

  test "runtime accepts custom redaction key names" do
    runtime =
      Runtime.new(redact_keys: [:tenant_id, "customer-secret"])
      |> Runtime.trace(%{
        "customer-secret" => "visible but sensitive",
        tenant_id: "tenant-public",
        api_key: "sk-live"
      })

    assert [
             %{
               "customer-secret" => "[REDACTED]",
               tenant_id: "[REDACTED]",
               api_key: "[REDACTED]"
             }
           ] = runtime.traces
  end

  test "runtime redacts secret-shaped values under unexpected keys" do
    echo = Imp.Tool.new(:echo, "echo", fn input -> input end)

    agent =
      Agent.new(
        :redactor,
        fn agent, _input, runtime ->
          Agent.call_tool(
            agent,
            :echo,
            %{
              harmless: "visible",
              random_header: "Bearer abcdefghijklmnopqrstuvwxyz0123456789",
              nested: %{odd_name: "sk-abcdefghijklmnopqrstuvwxyz"}
            },
            runtime
          )
        end,
        tools: [echo]
      )

    assert {:ok, _output, runtime} = Agent.run(agent, %{})

    assert [
             %{
               input: %{
                 harmless: "visible",
                 random_header: "[REDACTED]",
                 nested: %{odd_name: "[REDACTED]"}
               }
             },
             %{output: %{random_header: "[REDACTED]", nested: %{odd_name: "[REDACTED]"}}}
           ] = runtime.traces
  end

  test "agent returns structured failures for tools children and schemas" do
    boom = Imp.Tool.new(:boom, "raises", fn _ -> raise "nope" end)

    agent =
      Agent.new(
        :parent,
        fn _inputs, runtime -> Agent.call_tool(agent_ref(), :boom, %{}, runtime) end,
        tools: [boom]
      )

    Process.put(:agent_ref, agent)

    assert {:error, {:tool_error, :boom, "nope"}, runtime} = Agent.run(agent, %{})
    assert [%{type: :tool_error}, %{type: :agent_error}] = runtime.traces

    required =
      Agent.new(:required, fn input, runtime -> {:ok, input, runtime} end,
        input_schema: %{required: [:x]}
      )

    assert {:error, {:missing_required, [:x]}, _runtime} = Agent.run(required, %{})
  after
    Process.delete(:agent_ref)
  end

  test "agent stream emits output and traces" do
    agent = Agent.new(:streamer, fn %{x: x}, runtime -> {:ok, %{x: x + 1}, runtime} end)

    assert [%{type: :output, output: %{x: 2}}, %{type: :trace, traces: traces}] =
             Agent.stream(agent, %{x: 1}) |> Enum.to_list()

    assert [%{type: :agent, agent: :streamer}] = traces
  end

  test "agent stream_events emits trace events before final output" do
    normalize =
      Imp.Tool.new(:normalize, "normalize text", fn %{text: text} ->
        String.downcase(text)
      end)

    agent =
      Agent.new(
        :streamer,
        fn agent, %{text: text}, runtime ->
          Agent.call_tool(agent, :normalize, %{text: text}, runtime)
        end,
        tools: [normalize]
      )

    events = Agent.stream_events(agent, %{text: "HeLLo"}) |> Enum.to_list()

    assert [
             %{type: :trace, event: %{type: :tool, tool: :normalize}},
             %{type: :trace, event: %{type: :agent, agent: :streamer}},
             %{type: :output, output: "hello"}
           ] = events
  end

  test "event sink exceptions are surfaced loudly without killing the run" do
    parent = self()
    handler_id = "agent-sink-exception-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:imp, :agent, :event_sink, :exception],
        fn event, measurements, metadata, _config ->
          send(parent, {:sink_exception, event, measurements, metadata})
        end,
        nil
      )

    runtime = Runtime.new(event_sink: fn _event -> raise "sink exploded" end)
    agent = Agent.new(:worker, fn %{x: x}, runtime -> {:ok, %{x: x + 1}, runtime} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{x: 2}, runtime} = Agent.run(agent, %{x: 1}, runtime)
        assert [%{type: :agent, agent: :worker}] = runtime.traces
      end)

    assert log =~ "event sink"
    assert log =~ "sink exploded"

    assert_received {:sink_exception, [:imp, :agent, :event_sink, :exception], _measurements,
                     metadata}

    assert metadata.error =~ "sink exploded"
  end

  test "event sink throws and exits are surfaced loudly without killing the run" do
    parent = self()
    handler_id = "agent-sink-throw-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:imp, :agent, :event_sink, :exception],
        fn event, measurements, metadata, _config ->
          send(parent, {:sink_exception, event, measurements, metadata})
        end,
        nil
      )

    runtime = Runtime.new(event_sink: fn _event -> throw(:sink_bailed) end)
    agent = Agent.new(:worker, fn %{x: x}, runtime -> {:ok, %{x: x + 1}, runtime} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{x: 2}, _runtime} = Agent.run(agent, %{x: 1}, runtime)
      end)

    assert log =~ "event sink"
    assert log =~ "sink_bailed"

    assert_received {:sink_exception, [:imp, :agent, :event_sink, :exception], _measurements,
                     metadata}

    assert metadata.error =~ "sink_bailed"
  end

  test "missing context references become structured errors instead of raw tuples" do
    agent = Agent.new(:reader, fn inputs, runtime -> {:ok, inputs, runtime} end)

    assert {:error, {:missing_context, [:document]}, runtime} =
             Agent.run(agent, %{doc: {:context_ref, :document}}, Runtime.new())

    assert [
             %{type: :agent_error, agent: :reader, error: {:missing_context, [:document]}}
           ] = runtime.traces
  end

  test "moduledoc does not overclaim typed validation" do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(Imp.Agent)

    refute moduledoc =~ ~r/typed agent/i
    assert moduledoc =~ "required-key presence"
  end

  defp agent_ref, do: Process.get(:agent_ref)
end
