defmodule MCPImportTest do
  use ExUnit.Case, async: true

  alias DSEx.Agent
  alias DSEx.MCP

  defmodule MCPTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, _opts) do
      decoded = Jason.decode!(body)
      request = %{url: url, headers: headers, body: decoded}
      Process.put(:mcp_requests, Process.get(:mcp_requests, []) ++ [request])

      case decoded do
        %{"method" => "initialize", "jsonrpc" => "2.0", "id" => _id} ->
          {:ok, %{status: 200, headers: [], body: Jason.encode!(%{"result" => %{}})}}

        %{"method" => "notifications/initialized", "jsonrpc" => "2.0"} ->
          {:ok, %{status: 202, headers: [], body: Jason.encode!(%{})}}

        %{"method" => "tools/list", "jsonrpc" => "2.0", "id" => _id} ->
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

        %{
          "method" => "tools/call",
          "jsonrpc" => "2.0",
          "id" => _id,
          "params" => %{"arguments" => %{"key" => key}}
        } ->
          {:ok,
           %{status: 200, headers: [], body: Jason.encode!(%{"result" => %{"value" => key}})}}
      end
    end
  end

  defmodule MCPErrorTransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(_url, _headers, body, _opts) do
      decoded = Jason.decode!(body)

      response =
        case decoded["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => decoded["id"], "result" => %{}}

          "notifications/initialized" ->
            %{"jsonrpc" => "2.0", "result" => %{}}

          "tools/list" ->
            %{
              "jsonrpc" => "2.0",
              "id" => decoded["id"],
              "result" => %{
                "tools" => [
                  %{
                    "name" => "remote_fail",
                    "description" => "fails remotely",
                    "input_schema" => %{"type" => "object"}
                  }
                ]
              }
            }

          "tools/call" ->
            %{
              "jsonrpc" => "2.0",
              "id" => decoded["id"],
              "error" => %{"code" => -32_000, "message" => "remote failed"}
            }
        end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(response)}}
    end
  end

  defmodule MCPSSETransport do
    @behaviour DSEx.HTTP

    @impl true
    def post(url, headers, body, opts) do
      with {:ok, %{body: response}} <- MCPTransport.post(url, headers, body, opts) do
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "text/event-stream"}],
           body: "event: message\ndata: #{response}\n\n"
         }}
      end
    end
  end

  defmodule MalformedCatalog do
    defstruct [:result]

    def list_tools(%__MODULE__{result: result}), do: result
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

    assert {:error, {:missing_required, [:key]}} = DSEx.Tool.call(tool, %{})
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

    assert {:ok, 3} = DSEx.Tool.call(tool, %{external_key => 3})

    assert {:error, {:schema_validation, [%{field: ^external_key, rule: :type}]}} =
             DSEx.Tool.call(tool, %{external_key => "bad"})

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

  test "MCP import rejects malformed catalog and tool schema shapes clearly" do
    assert_raise ArgumentError, ~r/MCP catalog list_tools\/1 must return a list/, fn ->
      MCP.import_tools(%MalformedCatalog{result: %{tools: []}})
    end

    assert_raise ArgumentError, ~r/MCP tool schema must be a map/, fn ->
      MCP.import_tools(["not-a-tool-schema"])
    end
  end

  test "MCP import validates schema field types before wrapping tools" do
    base = %{
      name: :lookup,
      description: "lookup",
      input_schema: %{},
      run: fn input -> input end
    }

    assert_raise ArgumentError, ~r/MCP tool name must be an atom or string/, fn ->
      MCP.import_tools([%{base | name: 123}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup description must be a string/, fn ->
      MCP.import_tools([%{base | description: nil}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup input_schema must be a map/, fn ->
      MCP.import_tools([%{base | input_schema: []}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup run must be a one-argument function/, fn ->
      MCP.import_tools([%{base | run: fn _, _ -> :ok end}])
    end
  end

  test "HTTP MCP client discovers tools through injectable transport" do
    ref = DSEx.Test.TelemetryHelpers.attach([[:dsex, :mcp, :http, :start]])

    client = MCP.HTTPClient.new("https://mcp.example/tools", transport: MCPTransport)

    [tool] = MCP.import_tools(client)

    assert tool.name == "remote_lookup"
    assert %{"value" => "abc"} = DSEx.Tool.call(tool, %{"key" => "abc"})

    assert [init_request, initialized_request, list_request, call_request] =
             Process.get(:mcp_requests)

    assert init_request.body["method"] == "initialize"
    assert initialized_request.body["method"] == "notifications/initialized"
    assert list_request.url == "https://mcp.example/tools"
    assert list_request.body["jsonrpc"] == "2.0"
    assert list_request.body["method"] == "tools/list"
    assert call_request.body["method"] == "tools/call"
    assert_received {^ref, [:dsex, :mcp, :http, :start], _, %{method: "initialize"}}
    assert_received {^ref, [:dsex, :mcp, :http, :start], _, %{method: "tools/list"}}
    assert_received {^ref, [:dsex, :mcp, :http, :start], _, %{method: "tools/call"}}
  after
    Process.delete(:mcp_requests)
  end

  test "HTTP MCP client returns JSON-RPC errors as tool errors" do
    [tool] =
      "https://mcp.example/tools"
      |> MCP.HTTPClient.new(transport: MCPErrorTransport)
      |> MCP.import_tools()

    assert {:error, {:json_rpc_error, %{"code" => -32_000, "message" => "remote failed"}}} =
             DSEx.Tool.call(tool, %{})
  end

  test "stdio MCP client encodes JSON-RPC lines for process transports" do
    line = MCP.StdioClient.encode("tools/list", %{}, 123)

    assert String.ends_with?(line, "\n")

    assert %{"jsonrpc" => "2.0", "id" => 123, "method" => "tools/list", "params" => %{}} =
             Jason.decode!(line)
  end

  test "stdio MCP client returns JSON-RPC errors as tool errors" do
    script =
      Path.join(
        System.tmp_dir!(),
        "dsex_mcp_stdio_error_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(script, """
    import json
    import sys

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        response = None

        if method == "initialize":
            response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {}}
        elif method == "tools/list":
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "result": {
                    "tools": [
                        {
                            "name": "stdio_fail",
                            "description": "fails through stdio",
                            "input_schema": {"type": "object"},
                        }
                    ]
                },
            }
        elif method == "tools/call":
            response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {"code": -32001, "message": "stdio failed"},
            }

        if response is not None:
            sys.stdout.write(json.dumps(response) + "\\n")
            sys.stdout.flush()
    """)

    on_exit(fn -> File.rm(script) end)

    [tool] =
      System.find_executable("python3")
      |> MCP.StdioClient.new(args: [script])
      |> MCP.import_tools()

    assert {:error, {:json_rpc_error, %{"code" => -32_001, "message" => "stdio failed"}}} =
             DSEx.Tool.call(tool, %{})
  end

  test "streamable HTTP MCP client sends session headers and decodes SSE data" do
    client =
      MCP.StreamableHTTPClient.new("https://mcp.example/stream",
        transport: MCPSSETransport,
        session_id: "session-1"
      )

    [tool] = MCP.import_tools(client)

    assert tool.name == "remote_lookup"
    assert %{"value" => "abc"} = DSEx.Tool.call(tool, %{"key" => "abc"})

    assert [init_request, list_request, call_request] = Process.get(:mcp_requests)
    assert {"mcp-session-id", "session-1"} in init_request.headers
    assert {"accept", "application/json, text/event-stream"} in list_request.headers
    assert call_request.body["method"] == "tools/call"
  after
    Process.delete(:mcp_requests)
  end

  test "streamable HTTP MCP client returns JSON-RPC errors as tool errors" do
    [tool] =
      "https://mcp.example/stream"
      |> MCP.StreamableHTTPClient.new(transport: MCPErrorTransport)
      |> MCP.import_tools()

    assert {:error, {:json_rpc_error, %{"code" => -32_000, "message" => "remote failed"}}} =
             DSEx.Tool.call(tool, %{})
  end

  defp agent_ref, do: Process.get(:agent_ref)
end
