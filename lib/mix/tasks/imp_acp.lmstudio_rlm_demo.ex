defmodule Mix.Tasks.ImpAcp.LmstudioRlmDemo do
  @shortdoc "Runs a real LM Studio-backed RLM ACP agent"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: &program/1,
      agent_info: %{"name" => "imp-rlm-lmstudio", "version" => "0.1.0"}
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
          capabilities: %{chat: true},
          extra: %{wire: %{protocol: "openai_chat"}}
        },
        api_key: "lm-studio",
        base_url: base_url(),
        cache: false
      )

    signature =
      Imp.signature(
        "question -> answer",
        "Use the constrained Elixir environment. Call workspace_name(%{}), then call " <>
          "submit(%{answer: observed_name}) with exactly the returned workspace name."
      )

    Imp.rlm(signature,
      lm: lm,
      adapter: Imp.Adapter.JSON,
      tools: [tool],
      max_iterations: 2,
      persistent: true
    )
  end

  defp model, do: System.get_env("IMP_LMSTUDIO_MODEL", "qwen/qwen3.6-35b-a3b")
  defp base_url, do: System.get_env("IMP_LMSTUDIO_BASE_URL", "http://127.0.0.1:1234/v1")
end
