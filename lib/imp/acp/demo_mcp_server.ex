defmodule Imp.ACP.DemoMCPServer do
  @moduledoc false

  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "imp-acp-demo-mcp", version: "0.1.0"

  tool "external_workspace_name", "Return the MCP server working directory name" do
    annotations(readOnlyHint: true)

    run(fn _arguments, state ->
      {:ok, Path.basename(File.cwd!()), state}
    end)
  end
end
