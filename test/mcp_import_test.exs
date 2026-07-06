defmodule MCPImportTest do
  use ExUnit.Case, async: true

  alias Dachshund.Agent
  alias Dachshund.MCP

  defmodule MCPTransport do
    @behaviour Dachshund.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      decoded = Jason.decode!(body)
      request = %{url: url, headers: headers, body: decoded}
      Process.put(:mcp_requests, Process.get(:mcp_requests, []) ++ [request])

      case decoded do
        %{"method" => "tools/list"} ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body:
               Jason.encode!(%{
                 "result" => %{
                   "tools" => [
                     %{
                       "name" => "remote_lookup",
                       "description" => "lookup remotely",
                       "input_schema" => %{"required" => ["key"]}
                     }
                   ]
                 }
               })
           }}

        %{"method" => "tools/call", "params" => %{"arguments" => %{"key" => key}}} ->
          {:ok,
           %{status: 200, headers: [], body: Jason.encode!(%{"result" => %{"value" => key}})}}
      end
    end
  end

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

    assert {:error, {:missing_required, [:key]}} = Dachshund.Tool.call(tool, %{})
  end

  test "imported MCP tools validate string-key JSON schema properties without atomizing keys" do
    external_key = "external_mcp_key_#{System.unique_integer([:positive])}"

    [tool] =
      MCP.import_tools([
        %{
          "name" => "score",
          "description" => "score a value",
          "input_schema" => %{
            "required" => [external_key],
            "properties" => %{
              external_key => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
            }
          },
          "run" => fn input -> {:ok, input[external_key]} end
        }
      ])

    assert {:ok, 3} = Dachshund.Tool.call(tool, %{external_key => 3})

    assert {:error, {:schema_validation, [%{field: ^external_key, rule: :type}]}} =
             Dachshund.Tool.call(tool, %{external_key => "bad"})

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "MCP import rejects duplicate tool names and malformed schemas" do
    duplicate = %{
      name: :lookup,
      description: "lookup",
      input_schema: %{},
      run: fn input -> input end
    }

    assert_raise ArgumentError, ~r/duplicate MCP tool names/, fn ->
      MCP.import_tools([duplicate, duplicate])
    end

    assert_raise ArgumentError, ~r/MCP tool schema missing run/, fn ->
      MCP.import_tools([Map.delete(duplicate, :run)])
    end
  end

  test "HTTP MCP client discovers tools through injectable transport" do
    client = MCP.HTTPClient.new("https://mcp.example/tools", transport: MCPTransport)

    [tool] = MCP.import_tools(client)

    assert tool.name == "remote_lookup"
    assert %{"value" => "abc"} = Dachshund.Tool.call(tool, %{"key" => "abc"})
    assert [list_request, call_request] = Process.get(:mcp_requests)
    assert list_request.url == "https://mcp.example/tools"
    assert list_request.body == %{"method" => "tools/list"}
    assert call_request.body["method"] == "tools/call"
  after
    Process.delete(:mcp_requests)
  end

  defp agent_ref, do: Process.get(:agent_ref)
end
