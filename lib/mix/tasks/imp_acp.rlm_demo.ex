defmodule Mix.Tasks.ImpAcp.RlmDemo do
  @shortdoc "Runs a deterministic Imp RLM ACP agent"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-rlm-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{cwd: cwd}) do
    workspace = Path.basename(cwd)

    tool =
      Imp.tool(:workspace_name, "Return the selected workspace name", fn _arguments ->
        workspace
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            reasoning: "Inspect the selected workspace through the RLM interpreter.",
            code: ~S|observed = workspace_name(%{})
submit(%{answer: "Imp RLM observed " <> observed <> "."})|
          }
        end
      )

    Imp.rlm("question -> answer",
      lm: lm,
      tools: [tool],
      max_iterations: 1,
      persistent: true
    )
  end
end
