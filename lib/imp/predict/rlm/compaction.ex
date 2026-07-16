defmodule Imp.Predict.RLM.Compaction do
  @moduledoc false

  @chars_per_token 4

  def estimator, do: :approximate_chars_per_4

  def should_compact?(messages, threshold_pct, context_tokens) when is_list(messages) do
    current_tokens = estimate_tokens(messages)
    threshold_tokens = trunc(threshold_pct * context_tokens)
    current_tokens >= threshold_tokens
  end

  def estimate_tokens(messages) do
    chars =
      Enum.reduce(messages, 0, fn message, total ->
        total + content_length(Map.get(message, :content, Map.get(message, "content", "")))
      end)

    div(chars + @chars_per_token - 1, @chars_per_token)
  end

  def summary_messages(messages) do
    messages ++
      [
        %{
          role: :user,
          content:
            "Summarize your progress so far. Include:\n" <>
              "1. Which steps/sub-tasks you have completed and which remain.\n" <>
              "2. Any concrete intermediate results (numbers, values, variable names) " <>
              "you computed - preserve these exactly.\n" <>
              "3. What your next action should be.\n" <>
              "Be concise (1-3 paragraphs) but preserve all key results and your " <>
              "current position in the task."
        }
      ]
  end

  def continuation(summary, count) do
    %{
      count: count,
      summary: summary,
      instruction:
        "Your conversation has been compacted #{count} time(s). " <>
          "Continue from the above summary. Do NOT repeat work you have already " <>
          "completed. Use SHOW_VARS() to check which REPL variables exist, " <>
          "and check history for full context. Your next action:"
    }
  end

  defp content_length(content) when is_binary(content), do: String.length(content)

  defp content_length(content) do
    content
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.length()
  end
end
