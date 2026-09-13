defmodule Imp.ACP.Prompt do
  @moduledoc false

  def text(blocks) when is_list(blocks) do
    text =
      blocks
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        %{type: "text", text: text} when is_binary(text) -> [text]
        %{type: :text, text: text} when is_binary(text) -> [text]
        _other -> []
      end)
      |> Enum.join("\n\n")

    if text == "", do: {:error, :text_prompt_required}, else: {:ok, text}
  end

  def text(_blocks), do: {:error, :invalid_prompt}
end
