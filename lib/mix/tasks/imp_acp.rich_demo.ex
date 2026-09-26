defmodule Mix.Tasks.ImpAcp.RichDemo do
  @shortdoc "Runs a deterministic live-event Imp ACP agent"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-react-v2-rich-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{cwd: cwd}) do
    tool =
      Imp.tool(:workspace_name, "Return the selected workspace name", fn _args ->
        Path.basename(cwd)
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Imp.ACP.DemoMessages.current_tool_result(messages) do
            {:error, _reason} ->
              "Workspace inspection was not authorized."

            {:ok, content} ->
              "Imp observed workspace #{content}."

            :none ->
              %{
                next_thought: "Inspect the selected workspace.",
                tool_calls: [
                  %{id: "workspace-name-1", name: "workspace_name", arguments: %{}}
                ]
              }
          end
        end
      )

    Imp.react("question -> answer", [tool], lm: lm, max_iters: 2)
  end
end
