defmodule MCPImportTest do
  use ExUnit.Case, async: true

  alias Imp.MCP
  alias Imp.MCP.ToolSchemas

  test "imports MCP tool schemas through the canonical tool boundary" do
    # MCP spec, Tool definition: camelCase "inputSchema" is the spec dialect.
    [tool] =
      ToolSchemas.to_tools!([
        %{
          "name" => "lookup",
          "description" => "lookup a value",
          "inputSchema" => %{"required" => ["key"]},
          "run" => fn %{key: key} -> %{value: "value:#{key}"} end
        }
      ])

    assert tool.name == "lookup"
    assert tool.schema == %{"required" => ["key"]}

    assert %{value: "value:abc"} = Imp.Tool.call(tool, %{key: "abc"})
  end

  test "imported MCP tools normalize validation errors" do
    # MCP spec, Tool definition: "description" is optional; omitted here.
    [tool] =
      ToolSchemas.to_tools!([
        %{
          "name" => "needs_key",
          "inputSchema" => %{"required" => ["key"]},
          "run" => fn _ -> :ok end
        }
      ])

    assert tool.description == ""
    assert {:error, {:missing_required, ["key"]}} = Imp.Tool.call(tool, %{})
  end

  test "tools without any input schema key fail loudly naming the spec key" do
    assert_raise ArgumentError, ~r/MCP tool :no_schema schema missing inputSchema/, fn ->
      ToolSchemas.to_tools!([%{name: :no_schema, run: fn input -> input end}])
    end

    # A server speaks the spec dialect; the snake_case spelling is not it.
    assert_raise ArgumentError, ~r/MCP tool :snake schema missing inputSchema/, fn ->
      ToolSchemas.to_tools!([%{name: :snake, input_schema: %{}, run: fn input -> input end}])
    end
  end

  test "imported MCP tools validate string-key JSON schema properties without atomizing keys" do
    external_key = "external_mcp_key_#{System.unique_integer([:positive])}"

    [tool] =
      ToolSchemas.to_tools!([
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
      ToolSchemas.to_tools!([duplicate, duplicate])
    end

    assert_raise ArgumentError, ~r/MCP tool schema missing run/, fn ->
      ToolSchemas.to_tools!([Map.delete(duplicate, :run)])
    end
  end

  test "MCP import rejects malformed tool schema shapes clearly" do
    assert_raise ArgumentError, ~r/MCP tool schemas must be a list/, fn ->
      ToolSchemas.to_tools!(%{tools: []})
    end

    assert_raise ArgumentError, ~r/MCP tool schema must be a map/, fn ->
      ToolSchemas.to_tools!(["not-a-tool-schema"])
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
      ToolSchemas.to_tools!([%{base | name: 123}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup description must be a string/, fn ->
      ToolSchemas.to_tools!([%{base | description: 123}])
    end

    # MCP spec, Tool definition: description is Optional[str]; explicit null
    # from a server means "no description" and normalizes to "".
    [tool] = ToolSchemas.to_tools!([%{base | description: nil}])
    assert tool.description == ""

    assert_raise ArgumentError, ~r/MCP tool :lookup inputSchema must be a map/, fn ->
      ToolSchemas.to_tools!([%{base | inputSchema: []}])
    end

    assert_raise ArgumentError, ~r/MCP tool :lookup run must be a one-argument function/, fn ->
      ToolSchemas.to_tools!([%{base | run: fn _, _ -> :ok end}])
    end
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

    assert {:error, {:mcp_tool_error, %{"structuredContent" => %{"ignored" => true}}}} =
             MCP.tool_result(
               %{
                 "content" => [%{"type" => "text", "text" => "boom"}],
                 "structuredContent" => %{"ignored" => true},
                 "isError" => true
               },
               :structured
             )
  end
end
