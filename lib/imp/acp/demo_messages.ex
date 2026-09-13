defmodule Imp.ACP.DemoMessages do
  @moduledoc false

  # ReActV2 appends a final user-formatting message after the current tool
  # result. A tool from an earlier retained-history turn must not be mistaken
  # for a result produced by the current prompt.
  def current_tool_result(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(not current_question?(&1)))
    |> Enum.find(&(Map.get(&1, :role) == :tool))
    |> case do
      %{content: content} -> classify(content)
      nil -> :none
    end
  end

  defp current_question?(%{role: :user, content: content}) when is_binary(content),
    do: String.contains?(content, "[[ ## question ## ]]")

  defp current_question?(_message), do: false

  defp classify({:error, _reason} = error), do: {:error, error}

  defp classify(content) when is_binary(content) do
    if String.starts_with?(content, "{:error,"), do: {:error, content}, else: {:ok, content}
  end

  defp classify(content), do: {:ok, content}
end
