defmodule MCPImportTest do
  use ExUnit.Case, async: true

  alias DSPy.Agent
  alias DSPy.MCP

  test "imports MCP-style catalog tools and runs them through an agent" do
    catalog =
      MCP.Catalog.new([
        %{
          name: :lookup,
          description: "lookup a value",
          input_schema: %{required: [:key]},
          run: fn %{key: key} -> %{value: "value:#{key}"} end
        }
      ])

    [tool] = MCP.import_tools(catalog)
    assert tool.name == :lookup
    assert tool.schema == %{required: [:key]}

    agent =
      Agent.new(
        :lookup_agent,
        fn %{key: key}, runtime ->
          Agent.call_tool(agent_ref(), :lookup, %{key: key}, runtime)
        end,
        tools: [tool]
      )

    Process.put(:agent_ref, agent)

    assert {:ok, %{value: "value:abc"}, runtime} = Agent.run(agent, %{key: "abc"})
    assert [%{type: :tool, tool: :lookup}, %{type: :agent}] = runtime.traces
  after
    Process.delete(:agent_ref)
  end

  test "imported MCP tools normalize validation errors" do
    [tool] =
      MCP.import_tools([
        %{
          name: :needs_key,
          description: "needs key",
          input_schema: %{required: [:key]},
          run: fn _ -> :ok end
        }
      ])

    assert {:error, {:missing_required, [:key]}} = DSPy.Tool.call(tool, %{})
  end

  defp agent_ref, do: Process.get(:agent_ref)
end
