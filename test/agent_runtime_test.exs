defmodule AgentRuntimeTest do
  use ExUnit.Case, async: true

  alias DSEx.Agent
  alias DSEx.Agent.Runtime

  test "agent forwards typed inputs through tools and child agents with trace capture" do
    normalize =
      DSEx.Tool.new(:normalize, "normalize text", fn %{text: text} ->
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

  test "arity-3 handlers receive the agent without process dictionary self-reference" do
    normalize =
      DSEx.Tool.new(:normalize, "normalize text", fn %{text: text} ->
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
    boom = DSEx.Tool.new(:boom, "blocked", fn _ -> raise "should not run" end)

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

  test "runtime redacts sensitive trace keys" do
    echo = DSEx.Tool.new(:echo, "echo", fn input -> input end)

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

  test "agent returns structured failures for tools children and schemas" do
    boom = DSEx.Tool.new(:boom, "raises", fn _ -> raise "nope" end)

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
      DSEx.Tool.new(:normalize, "normalize text", fn %{text: text} ->
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

  defp agent_ref, do: Process.get(:agent_ref)
end
