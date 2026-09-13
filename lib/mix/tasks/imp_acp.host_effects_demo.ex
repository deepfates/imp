defmodule Mix.Tasks.ImpAcp.HostEffectsDemo do
  @shortdoc "Runs deterministic ACP-hosted write and terminal effects"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      permission_policy: &Imp.ACP.Host.permission_policy/2,
      agent_info: %{"name" => "imp-acp-host-effects-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{host: host}) do
    tools = Imp.ACP.Host.tools(host, only: [:write_file, :run_command])

    {:ok, step} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Agent.get_and_update(step, &{&1, &1 + 1}) do
            0 ->
              tool_turn("Create the proof through the ACP host.", "write_file", "host-write", %{
                path: "imp-acp-host-proof.txt",
                content: "hosted\n"
              })

            1 ->
              tool_turn(
                "Verify the proof in the ACP host terminal.",
                "run_command",
                "host-cat",
                %{
                  command: "cat",
                  args: ["imp-acp-host-proof.txt"]
                }
              )

            _ ->
              result =
                case Imp.ACP.DemoMessages.current_tool_result(messages) do
                  {:ok, content} -> content
                  {:error, reason} -> "host effect failed: #{inspect(reason)}"
                  :none -> "host effect produced no result"
                end

              tool_turn("Return the host-observed result.", "submit", "host-submit", %{
                answer: result
              })
          end
        end
      )

    program = Imp.react_v2("question -> answer", tools, lm: lm, max_iters: 3)
    {:ok, program, fn -> if Process.alive?(step), do: Agent.stop(step) end}
  end

  defp tool_turn(thought, name, id, arguments) do
    %{next_thought: thought, tool_calls: [%{id: id, name: name, arguments: arguments}]}
  end
end
