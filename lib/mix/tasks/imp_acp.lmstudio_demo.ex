defmodule Mix.Tasks.ImpAcp.LmstudioDemo do
  @shortdoc "Runs a real LM Studio-backed ReActV2 ACP agent"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-react-v2-lmstudio", "version" => "0.1.0"}
    )
  end

  defp program(%{cwd: cwd}) do
    tool =
      Imp.tool(:workspace_name, "Return the basename of the selected workspace", fn _args ->
        Path.basename(cwd)
      end)

    model = model()

    lm =
      Imp.req_llm(
        %{
          provider: :openai,
          id: model,
          model: model,
          provider_model_id: model,
          capabilities: %{chat: true, tools: %{enabled: true}},
          extra: %{wire: %{protocol: "openai_chat"}}
        },
        api_key: "lm-studio",
        base_url: base_url(),
        cache: false
      )

    Imp.react("question -> answer", [tool], lm: lm, max_iters: 4)
  end

  defp model, do: System.get_env("IMP_LMSTUDIO_MODEL", "qwen/qwen3.6-35b-a3b")
  defp base_url, do: System.get_env("IMP_LMSTUDIO_BASE_URL", "http://127.0.0.1:1234/v1")
end
