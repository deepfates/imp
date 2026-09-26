defmodule MCPReferenceServerLiveTest do
  @moduledoc """
  Live interop gate against the official MCP reference filesystem server
  (`@modelcontextprotocol/server-filesystem` via npx, stdio transport).

  This is the honest version of the import path: a real spec-compliant server
  whose tools/list emits camelCase `inputSchema` (MCP spec, Tool definition),
  imported through `Imp.MCP.connect/2`. Excluded by default; run with:

      mix test --include live test/mcp_reference_server_live_test.exs
  """
  use ExUnit.Case

  @moduletag :live
  @moduletag timeout: 120_000

  test "imports and calls tools from the official filesystem MCP server over stdio" do
    npx =
      System.find_executable("npx") || flunk("npx not found; install Node.js to run this gate")

    root =
      Path.join(System.tmp_dir!(), "imp_mcp_reference_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    fixture = Path.join(root, "fact.txt")
    File.write!(fixture, "BEAM interop")

    tools =
      npx
      |> Imp.Test.MCPConnect.stdio!(
        args: ["-y", "@modelcontextprotocol/server-filesystem", root],
        timeout: 60_000
      )
      |> Map.fetch!(:tools)

    assert tools != []

    # Every imported tool carries a map schema taken from the spec's
    # camelCase inputSchema key.
    assert Enum.all?(tools, &(is_map(&1.schema) and is_binary(&1.description)))

    read_tool =
      Enum.find(tools, &(to_string(&1.name) in ["read_text_file", "read_file"])) ||
        flunk(
          "reference server exposed no read tool; got: #{inspect(Enum.map(tools, & &1.name))}"
        )

    assert read_tool.schema["type"] == "object"

    result = Imp.Tool.call(read_tool, %{"path" => fixture})

    assert %{"content" => content} = result
    assert Enum.any?(content, &(&1["text"] =~ "BEAM interop"))
  end
end
