defmodule Mix.Tasks.ImpAcp.HostTerminalCancelDemo do
  @shortdoc "Runs a cancellable command in an ACP-hosted terminal"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      permission_policy: &Imp.ACP.Host.permission_policy/2,
      agent_info: %{"name" => "imp-acp-host-terminal-cancel-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{host: host}) do
    [run_command] = Imp.ACP.Host.tools(host, only: [:run_command])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Imp.ACP.DemoMessages.current_tool_result(messages) do
            :none ->
              tool_turn("Start a cancellable host terminal.", "run_command", "host-sleep", %{
                command: "sleep",
                args: ["30"]
              })

            {:ok, result} ->
              result

            {:error, reason} ->
              "host terminal failed: #{inspect(reason)}"
          end
        end
      )

    Imp.react_v2("question -> answer", [run_command], lm: lm, max_iters: 2)
  end

  defp tool_turn(thought, name, id, arguments) do
    %{next_thought: thought, tool_calls: [%{id: id, name: name, arguments: arguments}]}
  end
end
