defmodule Mix.Tasks.WorkspaceAgent.Preflight do
  @shortdoc "Check the private workspace-agent prerequisites"

  use Mix.Task

  @impl true
  def run(args) do
    {:ok, _apps} = Application.ensure_all_started(:req)

    workspace = args |> List.first() |> then(&(&1 || File.cwd!())) |> Path.expand()

    checks = [
      {"workspace", File.dir?(workspace), workspace},
      {"Toad", not is_nil(toad_executable()), toad_executable()},
      {"LM Studio", provider_ready?(), WorkspaceAgent.base_url()},
      {"model", model_ready?(), WorkspaceAgent.model()}
    ]

    Enum.each(checks, fn {name, ready?, detail} ->
      marker = if ready?, do: "ok", else: "missing"
      Mix.shell().info("#{marker}\t#{name}\t#{detail}")
    end)

    if Enum.all?(checks, &elem(&1, 1)) do
      Mix.shell().info(
        "\nMounting #{workspace} grants this session bounded list/read/search access."
      )

      Mix.shell().info("\nReady. Launch persistent RLM with:")

      Mix.shell().info(
        "  #{shell_quote(toad_executable())} acp #{shell_quote(launcher())} #{shell_quote(workspace)}"
      )

      Mix.shell().info("\nUse WORKSPACE_AGENT_PROGRAM=react for restart-durable ReActV2.")
    else
      Mix.raise("workspace-agent preflight failed")
    end
  end

  defp provider_ready? do
    match?({:ok, %Req.Response{status: 200}}, models_response())
  end

  defp model_ready? do
    case models_response() do
      {:ok, %Req.Response{status: 200, body: %{"data" => models}}} when is_list(models) ->
        Enum.any?(models, &(Map.get(&1, "id") == WorkspaceAgent.model()))

      _other ->
        false
    end
  end

  defp models_response do
    Process.get(:workspace_agent_models_response) ||
      Req.get(models_url(), receive_timeout: 5_000)
      |> tap(&Process.put(:workspace_agent_models_response, &1))
  rescue
    _error -> {:error, :unreachable}
  end

  defp models_url do
    WorkspaceAgent.base_url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/models")
  end

  defp launcher do
    Path.expand("scripts/workspace-agent-acp", File.cwd!())
  end

  defp toad_executable do
    System.find_executable("toad") || user_local_toad()
  end

  defp user_local_toad do
    candidate = Path.join([System.user_home!(), ".local", "bin", "toad"])
    if File.regular?(candidate), do: candidate
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
