defmodule Mix.Tasks.ImpAcp.McpDemo do
  @shortdoc "Runs an Imp ACP agent that consumes authorized ACP MCP servers"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-react-v2-mcp-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{cwd: cwd, mcp_servers: servers}) do
    with {:ok, import} <-
           Imp.ACP.MCP.import_tools(servers,
             cwd: cwd,
             trusted_servers: [demo_server()],
             result_mode: :text
           ) do
      {:ok, Imp.react_v2("question -> answer", import.tools, lm: lm(), max_iters: 2),
       %{cleanup: import.cleanup, tool_kinds: import.tool_kinds}}
    end
  end

  # Even the demo trusts an operator-known descriptor, never the client list
  # merely because it arrived in session/new.
  defp demo_server do
    %{
      "name" => "imp-acp-demo",
      "type" => "stdio",
      "command" => System.find_executable("mix"),
      "args" => ["imp_acp.demo_mcp_server"],
      "env" => []
    }
  end

  defp lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        case Imp.ACP.DemoMessages.current_tool_result(messages) do
          {:error, _reason} ->
            "The MCP tool request was not authorized."

          {:ok, content} ->
            "MCP returned workspace #{content}."

          :none ->
            %{
              next_thought: "Ask the authorized MCP server.",
              tool_calls: [
                %{id: "mcp-workspace", name: "external_workspace_name", arguments: %{}}
              ]
            }
        end
      end
    )
  end
end
