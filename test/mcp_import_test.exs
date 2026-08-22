defmodule MCPImportTest do
  use ExUnit.Case, async: true

  alias Imp.Agent
  alias Imp.MCP

  defmodule MCPTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(url, headers, body, opts) do
      decoded = Jason.decode!(body)
      request = %{url: url, headers: headers, body: decoded}

      case Keyword.get(opts, :test_pid) do
        nil -> :ok
        pid -> send(pid, {:mcp_request, request})
      end

      case decoded do
        %{"method" => "initialize", "jsonrpc" => "2.0", "id" => _id} ->
          {:ok, %{status: 200, headers: [], body: Jason.encode!(%{"result" => %{}})}}

        %{"method" => "notifications/initialized", "jsonrpc" => "2.0"} ->
          {:ok, %{status: 202, headers: [], body: Jason.encode!(%{})}}

        %{"method" => "tools/list", "jsonrpc" => "2.0", "id" => _id} ->
          # MCP spec, Tool definition: the input contract key is camelCase
          # "inputSchema", and "description" is optional (omitted here).
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
                       "inputSchema" => %{"required" => ["key"]}
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
          result =
            case key do
              "structured-false" ->
                %{
                  "content" => [%{"type" => "text", "text" => "fallback"}],
                  "structuredContent" => false,
                  "isError" => false
                }

              "text-result" ->
                %{
                  "content" => [%{"type" => "text", "text" => "from MCP"}],
                  "isError" => false
                }

              _other ->
                %{"value" => key}
            end

          {:ok, %{status: 200, headers: [], body: Jason.encode!(%{"result" => result})}}
      end
    end
  end

  defmodule MCPErrorTransport do
    @behaviour Imp.HTTP

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
            # MCP spec, Tool definition: camelCase "inputSchema".
            %{
              "jsonrpc" => "2.0",
              "id" => decoded["id"],
              "result" => %{
                "tools" => [
                  %{
                    "name" => "remote_fail",
                    "description" => "fails remotely",
                    "inputSchema" => %{"type" => "object"}
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
    @behaviour Imp.HTTP

    @impl true
    def post(url, headers, body, opts) do
      decoded = Jason.decode!(body)

      with {:ok, %{body: response}} <- MCPTransport.post(url, headers, body, opts) do
        case decoded["method"] do
          "notifications/initialized" ->
            # MCP spec, Streamable HTTP: notifications and responses receive
            # HTTP 202 Accepted with no body.
            {:ok, %{status: 202, headers: [], body: ""}}

          "initialize" ->
            # MCP spec, Streamable HTTP session management: the server MAY
            # assign a session id via the Mcp-Session-Id header on the
            # initialize response; the client MUST echo it afterwards.
            {:ok,
             %{
               status: 200,
               headers: [
                 {"content-type", "text/event-stream"},
                 {"mcp-session-id", "server-session-abc"}
               ],
               body: sse(response)
             }}

          _ ->
            {:ok,
             %{
               status: 200,
               headers: [{"content-type", "text/event-stream"}],
               body: sse(response)
             }}
        end
      end
    end

    defp sse(response), do: "event: message\ndata: #{response}\n\n"
  end

  defmodule MalformedCatalog do
    defstruct [:result]

    def list_tools(%__MODULE__{result: result}), do: result
  end

  defmodule RaisingCatalog do
    defstruct []

    def list_tools(%__MODULE__{}), do: raise("catalog exploded")
  end

  defmodule MissingToolsCatalog do
    defstruct [:name]
  end

  test "imports MCP-style catalog tools and runs them through an agent" do
    # MCP spec, Tool definition: camelCase "inputSchema" is the spec dialect.
    catalog =
      MCP.Catalog.new([
        %{
          "name" => "lookup",
          "description" => "lookup a value",
          "inputSchema" => %{"required" => ["key"]},
          "run" => fn %{key: key} -> %{value: "value:#{key}"} end
        }
      ])

    [tool] = MCP.import_tools(catalog)
    assert tool.name == :lookup
    assert tool.schema == %{"required" => ["key"]}

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

  test "MCP client constructors reject invalid positional boundaries" do
    assert_raise ArgumentError,
                 ~r/Imp\.MCP\.Catalog\.new\/1 expects a list of tool schemas/,
                 fn ->
                   MCP.Catalog.new(%{tools: []})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.MCP\.HTTPClient\.new\/2 expects url to be a binary/,
                 fn ->
                   MCP.HTTPClient.new(:not_a_url)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.MCP\.StreamableHTTPClient\.new\/2 expects url to be a binary/,
                 fn ->
                   MCP.StreamableHTTPClient.new(:not_a_url)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.MCP\.StdioClient\.new\/2 expects command to be a binary executable path/,
                 fn ->
                   MCP.StdioClient.new(:not_a_command)
                 end
  end

  test "imported MCP tools normalize validation errors" do
    # MCP spec, Tool definition: "description" is optional; omitted here.
    [tool] =
      MCP.import_tools([
        %{
          "name" => "needs_key",
          "inputSchema" => %{"required" => ["key"]},
          "run" => fn _ -> :ok end
        }
      ])

    assert tool.description == ""
    assert {:error, {:missing_required, ["key"]}} = Imp.Tool.call(tool, %{})
  end

  test "in-process catalogs may use snake_case input_schema as a documented fallback" do
    # Back-compat lane only: spec servers send camelCase "inputSchema"; the
    # snake_case atom spelling stays supported for in-process Elixir catalogs.
    [tool] =
      MCP.import_tools([
        %{
          name: :legacy_lookup,
          description: "legacy in-process schema",
          input_schema: %{required: [:key]},
          run: fn input -> input end
        }
      ])

    assert tool.schema == %{required: [:key]}
    assert {:error, {:missing_required, [:key]}} = Imp.Tool.call(tool, %{})
  end

  test "tools without any input schema key fail loudly naming the spec key" do
    assert_raise ArgumentError, ~r/MCP tool :no_schema schema missing inputSchema/, fn ->
      MCP.import_tools([%{name: :no_schema, run: fn input -> input end}])
    end
  end

  test "imported MCP tools validate string-key JSON schema properties without atomizing keys" do
    external_key = "external_mcp_key_#{System.unique_integer([:positive])}"

    [tool] =
      MCP.import_tools([
        %{
          "name" => "score",
          "description" => "score a value",
          "inputSchema" => %{
            "required" => [external_key],
            "properties" => %{
              external_key => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
            }
          },
          "run" => fn input -> {:ok, input[external_key]} end
        }
      ])

    assert {:ok, 3} = Imp.Tool.call(tool, %{external_key => 3})

    assert {:error, {:schema_validation, [%{field: ^external_key, rule: :type}]}} =
             Imp.Tool.call(tool, %{external_key => "bad"})

    assert_raise ArgumentError, fn -> String.to_existing_atom(external_key) end
  end

  test "MCP import rejects duplicate tool names and malformed schemas" do
    duplicate = %{
      name: :lookup,
      description: "lookup",
      inputSchema: %{},
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

    assert_raise ArgumentError,
                 ~r/MCP catalog .*RaisingCatalog.* list_tools\/1 failed: catalog exploded/,
                 fn ->
                   MCP.import_tools(%RaisingCatalog{})
                 end

    assert_raise ArgumentError,
                 ~r/MCP catalog .*MissingToolsCatalog.* must export list_tools\/1 or contain a :tools field/,
                 fn ->
                   MCP.import_tools(%MissingToolsCatalog{name: :empty})
                 end

    assert_raise ArgumentError, ~r/MCP tool schema must be a map/, fn ->
      MCP.import_tools(["not-a-tool-schema"])
    end
  end

  test "MCP import validates schema field types before wrapping tools" do
    base = %{
      name: :lookup,
      description: "lookup",
      inputSchema: %{},
      run: fn input -> input end
    }

    assert_raise ArgumentError, ~r/MCP tool name must be an atom or string/, fn ->
      MCP.import_tools([%{base | name: 123}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup description must be a string/, fn ->
      MCP.import_tools([%{base | description: 123}])
    end

    # MCP spec, Tool definition: description is Optional[str]; explicit null
    # from a server means "no description" and normalizes to "".
    [tool] = MCP.import_tools([%{base | description: nil}])
    assert tool.description == ""

    assert_raise ArgumentError, ~r/MCP tool :lookup inputSchema must be a map/, fn ->
      MCP.import_tools([%{base | inputSchema: []}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup run must be a one-argument function/, fn ->
      MCP.import_tools([%{base | run: fn _, _ -> :ok end}])
    end
  end

  test "HTTP MCP client discovers tools through injectable transport" do
    ref = Imp.Test.TelemetryHelpers.attach([[:imp, :mcp, :http, :start]])

    client =
      MCP.HTTPClient.new("https://mcp.example/tools",
        transport: MCPTransport,
        transport_opts: [test_pid: self()]
      )

    [tool] = MCP.import_tools(client)

    assert tool.name == "remote_lookup"
    assert %{"value" => "abc"} = Imp.Tool.call(tool, %{"key" => "abc"})

    assert [init_request, initialized_request, list_request, call_request] = receive_requests(4)

    assert init_request.body["method"] == "initialize"
    assert initialized_request.body["method"] == "notifications/initialized"
    assert list_request.url == "https://mcp.example/tools"
    assert list_request.body["jsonrpc"] == "2.0"
    assert list_request.body["method"] == "tools/list"
    assert call_request.body["method"] == "tools/call"
    assert_received {^ref, [:imp, :mcp, :http, :start], _, %{method: "initialize"}}
    assert_received {^ref, [:imp, :mcp, :http, :start], _, %{method: "tools/list"}}
    assert_received {^ref, [:imp, :mcp, :http, :start], _, %{method: "tools/call"}}
  end

  test "HTTP MCP client returns JSON-RPC errors as tool errors" do
    [tool] =
      "https://mcp.example/tools"
      |> MCP.HTTPClient.new(transport: MCPErrorTransport)
      |> MCP.import_tools()

    assert {:error, {:json_rpc_error, %{"code" => -32_000, "message" => "remote failed"}}} =
             Imp.Tool.call(tool, %{})
  end

  test "MCP CallToolResult conversion matches DSPy text and structured modes" do
    content = [%{"type" => "text", "text" => "fallback"}]

    for value <- [%{"answer" => 42}, [1, 2], "answer", 3.5, false, nil, %{}, [], "", 0] do
      result = %{"content" => content, "structuredContent" => value, "isError" => false}
      assert MCP.tool_result(result, :structured) === value
    end

    assert MCP.tool_result(%{"content" => content}, :text) == "fallback"
    assert MCP.tool_result(%{"content" => content}, :structured) == "fallback"

    assert MCP.tool_result(%{
             content: [
               %{type: :image, data: "abc"},
               %{type: :resource, uri: "file:///tmp/example"}
             ],
             is_error: false
           }) == [
             %{type: :image, data: "abc"},
             %{type: :resource, uri: "file:///tmp/example"}
           ]

    assert {:error, {:mcp_tool_error, "boom"}} =
             MCP.tool_result(
               %{
                 "content" => [%{"type" => "text", "text" => "boom"}],
                 "structuredContent" => %{"ignored" => true},
                 "isError" => true
               },
               :structured
             )
  end

  test "HTTP MCP client applies its selected result mode to ordinary imported tools" do
    [structured] =
      "https://mcp.example/tools"
      |> MCP.HTTPClient.new(transport: MCPTransport, result_mode: :structured)
      |> MCP.import_tools()

    [text] =
      "https://mcp.example/tools"
      |> MCP.HTTPClient.new(transport: MCPTransport, result_mode: :text)
      |> MCP.import_tools()

    assert Imp.Tool.call(structured, %{"key" => "structured-false"}) === false
    assert Imp.Tool.call(text, %{"key" => "text-result"}) == "from MCP"

    assert_raise ArgumentError, ~r/invalid value for :result_mode option/, fn ->
      MCP.HTTPClient.new("https://mcp.example/tools", result_mode: :raw)
    end
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
        "imp_mcp_stdio_error_#{System.unique_integer([:positive])}.exs"
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
                            "inputSchema": {"type": "object"},
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
             Imp.Tool.call(tool, %{})
  end

  test "streamable HTTP MCP client performs the spec handshake and decodes SSE data" do
    client =
      MCP.StreamableHTTPClient.new("https://mcp.example/stream",
        transport: MCPSSETransport,
        session_id: "session-1",
        transport_opts: [test_pid: self()]
      )

    [tool] = MCP.import_tools(client)

    assert tool.name == "remote_lookup"
    # MCP spec, Tool definition: description is optional; the mock omits it.
    assert tool.description == ""
    assert %{"value" => "abc"} = Imp.Tool.call(tool, %{"key" => "abc"})

    assert [init_request, initialized_request, list_request, call_request] = receive_requests(4)

    # MCP spec, Lifecycle: initialize MUST carry protocolVersion,
    # capabilities, and clientInfo.
    assert init_request.body["params"]["protocolVersion"] == "2025-03-26"
    assert init_request.body["params"]["clientInfo"]["name"] == "imp"
    assert Map.has_key?(init_request.body["params"], "capabilities")
    assert {"mcp-session-id", "session-1"} in init_request.headers

    # MCP spec, Lifecycle: the client MUST send notifications/initialized
    # after a successful initialize; notifications carry no id.
    assert initialized_request.body["method"] == "notifications/initialized"
    refute Map.has_key?(initialized_request.body, "id")

    # MCP spec, Streamable HTTP session management: the server-assigned
    # Mcp-Session-Id from the initialize response rides every later request.
    for request <- [initialized_request, list_request, call_request] do
      assert {"mcp-session-id", "server-session-abc"} in request.headers
    end

    assert {"accept", "application/json, text/event-stream"} in list_request.headers
    assert call_request.body["method"] == "tools/call"
  end

  test "streamable HTTP MCP client returns JSON-RPC errors as tool errors" do
    [tool] =
      "https://mcp.example/stream"
      |> MCP.StreamableHTTPClient.new(transport: MCPErrorTransport)
      |> MCP.import_tools()

    assert {:error, {:json_rpc_error, %{"code" => -32_000, "message" => "remote failed"}}} =
             Imp.Tool.call(tool, %{})
  end

  defp agent_ref, do: Process.get(:agent_ref)

  defp receive_requests(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:mcp_request, request}
      request
    end)
  end
end
