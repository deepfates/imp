defmodule Mix.Tasks.ImpAcp.HostDemo do
  @shortdoc "Runs a deterministic Imp agent using ACP-hosted filesystem tools"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      permission_policy: &Imp.ACP.Host.permission_policy/2,
      agent_info: %{"name" => "imp-acp-host-demo", "version" => "0.1.0"}
    )
  end

  defp program(%{host: host}) do
    [read_file] = Imp.ACP.Host.tools(host, only: [:read_file])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Imp.ACP.DemoMessages.current_tool_result(messages) do
            {:ok, content} ->
              answer = content |> String.split("\n") |> List.first()

              tool_turn("Return the host-supplied evidence.", "submit", "host-submit", %{
                answer: "ACP host supplied: #{answer}"
              })

            {:error, reason} ->
              tool_turn("Report the failed host read.", "submit", "host-failed", %{
                answer: "ACP host read failed: #{inspect(reason)}"
              })

            :none ->
              tool_turn("Ask the ACP host for the mounted README.", "read_file", "host-read", %{
                path: "README.md",
                line_start: 1,
                line_count: 1
              })
          end
        end
      )

    Imp.react_v2("question -> answer", [read_file], lm: lm, max_iters: 2)
  end

  defp tool_turn(thought, name, id, arguments) do
    %{next_thought: thought, tool_calls: [%{id: id, name: name, arguments: arguments}]}
  end
end
