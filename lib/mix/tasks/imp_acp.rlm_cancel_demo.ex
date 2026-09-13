defmodule Mix.Tasks.ImpAcp.RlmCancelDemo do
  @shortdoc "Runs an RLM ACP agent with a cancellable blocking tool effect"

  use Mix.Task

  @impl true
  def run(_args) do
    Imp.ACP.run(
      program_factory: fn _session -> program() end,
      agent_info: %{"name" => "imp-rlm-cancel-demo", "version" => "0.1.0"}
    )
  end

  defp program do
    marker = System.fetch_env!("IMP_CANCEL_MARKER")
    delay_ms = cancel_delay_ms()

    slow =
      Imp.tool(:slow, "Start a delayed effect", fn _args ->
        File.write!(marker, "started\n")
        Process.sleep(delay_ms)
        File.write!(marker, "late\n", [:append])
        "too late"
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            reasoning: "Run the delayed effect.",
            code: ~S|value = slow(%{})
submit(%{answer: value})|
          }
        end
      )

    Imp.rlm("question -> answer", lm: lm, tools: [slow], max_iterations: 1)
  end

  defp cancel_delay_ms do
    case Integer.parse(System.get_env("IMP_CANCEL_DELAY_MS", "5000")) do
      {delay_ms, ""} when delay_ms > 0 -> delay_ms
      _other -> raise "IMP_CANCEL_DELAY_MS must be a positive integer"
    end
  end
end
