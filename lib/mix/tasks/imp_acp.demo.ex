defmodule Mix.Tasks.ImpAcp.Demo do
  @shortdoc "Runs a provider-free ReActV2 ACP demonstration agent"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-react-v2-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{cwd: cwd}) do
    workspace = Path.basename(cwd)

    tool =
      Imp.tool(:workspace_name, "Return the current workspace name", fn _arguments ->
        workspace
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Imp.ACP.DemoMessages.current_tool_result(messages) do
            {:error, _reason} ->
              %{
                next_thought: "Respect the failed workspace inspection.",
                tool_calls: [
                  %{
                    id: "submit-workspace-denied",
                    name: "submit",
                    arguments: %{answer: "Workspace inspection was not authorized."}
                  }
                ]
              }

            {:ok, _content} ->
              %{
                next_thought: "The workspace tool supplied the answer.",
                tool_calls: [
                  %{
                    id: "submit-workspace",
                    name: "submit",
                    arguments: %{answer: "Imp ReActV2 is running in #{workspace}."}
                  }
                ]
              }

            :none ->
              %{
                next_thought: "Inspect the ACP workspace.",
                tool_calls: [
                  %{id: "read-workspace", name: "workspace_name", arguments: %{}}
                ]
              }
          end
        end
      )

    Imp.react_v2("question -> answer", [tool], lm: lm, max_iters: 2)
  end
end
