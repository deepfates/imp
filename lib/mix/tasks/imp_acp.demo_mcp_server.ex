defmodule Mix.Tasks.ImpAcp.DemoMcpServer do
  @shortdoc false

  use Mix.Task

  @impl true
  def run(_args) do
    silence_boot_logs()
    Mix.Task.run("app.start")
    {:ok, server} = Imp.ACP.DemoMCPServer.start_link(transport: :stdio)
    ref = Process.monitor(server)

    receive do
      {:DOWN, ^ref, :process, ^server, _reason} -> :ok
    end
  end

  defp silence_boot_logs do
    Logger.configure(level: :emergency)
    Application.put_env(:logger, :level, :emergency)
    :logger.set_primary_config(:level, :emergency)
  end
end
